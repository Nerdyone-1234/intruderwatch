#!/bin/bash
# Tests for mac/telegram-lib.sh – run: bash tests/test-telegram-lib.sh
# Telegram is NOT really contacted: tg_post is replaced by a fake.
cd "$(dirname "$0")/.." || exit 1
export IW_CONFIG=/dev/null   # don't load your own config.sh in tests
. mac/telegram-lib.sh
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export TG_QUEUE="$TMP/queue"
CFG="$TMP/config.json"; echo '{"token":"T","allowed_chat_id":"42"}' > "$CFG"; export TG_CONFIG="$CFG"
mkjpg(){ printf '\xff\xd8\xff\xe0jpg' > "$1"; }   # minimal JPEG signature
PHOTO="$TMP/photo.jpg"; mkjpg "$PHOTO"
SENT="$TMP/sent.txt"; : > "$SENT"
NET=down
tg_post(){ # $1 token $2 chat $3 photo $4 caption -> prints Telegram JSON
  [ "$NET" = up ] || return 7
  echo "$3|$4" >> "$SENT"; echo '{"ok":true,"result":{}}'
}
count(){ find "$TG_QUEUE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }

# 1) Network blocked -> goes to the queue
tg_send_or_queue "$PHOTO" "Alarm 1"; check "blocked -> returns 1" 1 $?
check "blocked -> 1 entry in queue" 1 "$(count)"
check "blocked -> nothing sent" 0 "$(wc -l < "$SENT" | tr -d ' ')"
check "queue holds only photo + caption (no token)" "caption.txt photo.jpg" "$(ls "$TG_QUEUE"/*/ | sort | xargs)"

# 2) The photo is a copy in the queue (survives deleting the original)
rm -f "$PHOTO"; check "photo copy in queue" 1 "$(ls "$TG_QUEUE"/*/photo.jpg 2>/dev/null | wc -l | tr -d ' ')"

# 3) Flush while still blocked -> stays queued
tg_flush_queue; check "flush without network -> stays" 1 "$(count)"

# 4) Network back -> flush sends and empties
NET=up; tg_flush_queue
check "flush with network -> queue empty" 0 "$(count)"
check "flush -> exactly 1 sent" 1 "$(grep -c "photo.jpg|" "$SENT")"
grep -q "Sent late" "$SENT"; check "caption marked as late" 0 $?
grep -q "Alarm 1" "$SENT"; check "original caption kept" 0 $?

# 5) Network up -> sent directly, no queue
: > "$SENT"; mkjpg "$PHOTO"
tg_send_or_queue "$PHOTO" "Alarm 2"; check "online -> returns 0" 0 $?
check "online -> queue empty" 0 "$(count)"

# 6) Telegram rejects permanently (400) -> NOT queued (would clog it)
tg_post(){ echo '{"ok":false,"error_code":400,"description":"Bad Request"}'; }
tg_send_or_queue "$PHOTO" "Alarm 3"; check "400 -> returns 2" 2 $?
check "400 -> not queued" 0 "$(count)"
# 6b) Telegram overloaded (429) -> temporary -> queued
tg_post(){ echo '{"ok":false,"error_code":429,"description":"Too Many Requests"}'; }
tg_send_or_queue "$PHOTO" "Alarm 3b"; check "429 -> queued" 1 "$(count)"

# 7) Missing config -> still queued (sent later)
rm -rf "$TG_QUEUE"; export TG_CONFIG="$TMP/missing.json"
tg_send_or_queue "$PHOTO" "Alarm 4"; check "no config -> queued" 1 "$(count)"

# 8) Text message (e.g. "turned off"): blocked -> queue, sent later
rm -rf "$TG_QUEUE"; export TG_CONFIG="$CFG"; : > "$SENT"; NET=down
tg_post_text(){ [ "$NET" = up ] || return 7; echo "TEXT|$3" >> "$SENT"; echo '{"ok":true}'; }
tg_post(){ [ "$NET" = up ] || return 7; echo "$3|$4" >> "$SENT"; echo '{"ok":true}'; }
tg_text_or_queue "Off"; check "text blocked -> returns 1" 1 $?
check "text blocked -> 1 entry" 1 "$(count)"
check "text entry without photo" "caption.txt" "$(ls "$TG_QUEUE"/*/ | xargs)"
NET=up; tg_flush_queue
check "text sent late -> queue empty" 0 "$(count)"
grep -q "^TEXT|" "$SENT" && grep -q "^Off" "$SENT"; check "sent as text (not photo)" 0 $?
tg_text_or_queue "On"; check "text online -> returns 0" 0 $?

# 9) (finding 2) A broken entry no longer blocks the queue
rm -rf "$TG_QUEUE"; : > "$SENT"; NET=down
tg_post(){ [ "$NET" = up ] || return 7
  case "$4" in *BROKEN*) echo '{"ok":false,"error_code":400}';; *) echo "$3|$4" >> "$SENT"; echo '{"ok":true}';; esac; }
tg_send_or_queue "$PHOTO" "BROKEN"; tg_send_or_queue "$PHOTO" "Alarm good"
check "2 entries waiting" 2 "$(count)"
NET=up; tg_flush_queue
check "queue empty afterwards" 0 "$(count)"
grep -q "Alarm good" "$SENT"; check "good entry still sent" 0 $?
check "broken entry moved to .failed" 1 "$(ls "$TG_QUEUE/.failed" | wc -l | tr -d ' ')"

# 10) (finding 2) Not a JPEG -> not sent and not queued
echo "cat: No such file" > "$TMP/fake.jpg"; : > "$SENT"
tg_send_or_queue "$TMP/fake.jpg" "x"; check "not a JPEG -> returns 2" 2 $?
check "not a JPEG -> not sent" 0 "$(wc -l < "$SENT" | tr -d ' ')"
check "not a JPEG -> not queued" 0 "$(count)"

# 11) (finding 3) A half-written entry (.tmp-*) is not touched by flush
mkdir -p "$TG_QUEUE/.tmp-half"; tg_flush_queue
check "half entry stays" 1 "$( [ -d "$TG_QUEUE/.tmp-half" ] && echo 1 || echo 0)"
rm -rf "$TG_QUEUE/.tmp-half"
# 11b) Entries only appear complete (no .tmp leftover after enqueue)
NET=down; tg_send_or_queue "$PHOTO" "Alarm 5"
check "no .tmp leftover" 0 "$(find "$TG_QUEUE" -maxdepth 1 -name '.tmp-*' | wc -l | tr -d ' ')"
check "finished entry has photo" 1 "$(ls "$TG_QUEUE"/2*/photo.jpg 2>/dev/null | wc -l | tr -d ' ')"

# 12) (finding 6) An old stale lock is overcome, a fresh one respected
NET=up; mkdir -p "$TG_QUEUE/.lock"; tg_flush_queue
check "fresh lock -> not sent" 1 "$(count)"
touch -t 202001010000 "$TG_QUEUE/.lock"; tg_flush_queue
check "old lock -> still sent" 0 "$(count)"
check "lock released afterwards" 0 "$( [ -d "$TG_QUEUE/.lock" ] && echo 1 || echo 0)"

echo "telegram-lib: $pass ok, $fail failed"; [ $fail -eq 0 ]
