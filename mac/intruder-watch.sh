#!/bin/bash
# Triggers intruder-snap.sh ONLY when someone enters the wrong password several
# times at the LOCKED Mac with the LID OPEN. Ignored: unlocked session (sudo typos,
# app prompts), closing/opening the lid (macOS logs auth failures then) and
# duplicate entries of the same attempt.
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
THRESH=2            # real failed attempts until the alarm
WINDOW=120          # within this many seconds
COOLDOWN=300        # quiet period afterwards
WAKE_GRACE=15       # ignore for this many seconds after waking up
LID_GRACE=2         # ignore for this many seconds after opening/waking. macOS writes
                    # its own failures only with the lid CLOSED (measured
                    # 2026-11-23); "lid closed" or log time < mark catches those.
BURST=2             # entries less than BURST s apart (log time) = one attempt
SETTLE=2            # wait briefly so the lid state is current
POLL=2              # polling interval for heartbeat/lid
SLEEP_GAP=10        # a poll gap larger than this = the Mac was asleep
FLUSH_EVERY=60      # seconds: retry queued Telegram photos
WARN_EVERY=3600     # "lock detection broken" warning at most this often
DIR="$HOME/Library/IntruderWatch"
PY=/opt/homebrew/bin/python3
HB="$DIR/.heartbeat"
LID="$DIR/.lid_closed_at"   # last moment: lid closed/opened, woke up, display on/off
DISP="$DIR/.display_state"  # awake|asleep, written by display-watch.py
log(){ echo "$(date '+%F %T') $*" >> "$DIR/watch.log"; }

# shellcheck source=watch-lib.sh
. "$DIR/watch-lib.sh" || { log "watch-lib.sh missing"; exit 1; }
# shellcheck source=telegram-lib.sh
. "$DIR/telegram-lib.sh" || { log "telegram-lib.sh missing"; exit 1; }

# Check lock detection. If is_locked.py returns neither locked nor unlocked (e.g.
# pyobjc missing after a Python update), the watcher would otherwise SILENTLY never fire.
WARNF="$DIR/.last_lock_warn"   # a file, because lock_state runs in $(...) (subshell)
lock_state(){
  local s; s=$("$PY" "$DIR/is_locked.py" 2>&1)
  case "$s" in
    locked|unlocked) echo "$s";;
    *) echo broken
       local now last; now=$(date +%s); last=$(cat "$WARNF" 2>/dev/null || echo 0)
       if [ $((now - last)) -ge $WARN_EVERY ]; then
         echo "$now" > "$WARNF"
         log "ERROR lock detection broken: $(echo "$s" | tail -1)"
         tg_text_or_queue "⚠️ IntruderWatch: lock detection broken – the alarm will NOT fire.
$(echo "$s" | tail -1)
Fix: /opt/homebrew/bin/pip3 install --break-system-packages pyobjc-framework-Quartz" >/dev/null
       fi;;
  esac
}
[ "$(lock_state)" = broken ] && log "start: lock detection broken (Telegram warning sent)"

# Background: heartbeat + time of the last lid/wake movement. The grace period
# LID_GRACE runs from OPENING/WAKING, not from the last "closed" before sleep
# (otherwise it would already have expired after a long sleep).
date +%s > "$HB"; date +%s > "$LID"
rmdir "$TG_QUEUE/.lock" 2>/dev/null   # stale lock after a crash/shutdown
( prev=$(date +%s); was=$(lid_state)
  while true; do
    now=$(date +%s); is=$(lid_state)
    [ -n "$(lid_mark "$prev" "$now" "$was" "$is" $SLEEP_GAP)" ] && echo "$now" > "$LID"
    echo "$now" > "$HB"; prev=$now; was=$is
    sleep $POLL
  done ) &
BGPID=$!
# Background: watch the display on/off (macOS writes its own failures on
# locking/display off, even with the lid open)
echo awake > "$DISP"
"$PY" "$DIR/display-watch.py" "$DIR" 2>>"$DIR/launchd.err" &
DWPID=$!
# Background: resend the Telegram queue (also right after login/restart)
( while true; do tg_flush_queue; sleep $FLUSH_EVERY; done ) &
FLPID=$!
trap 'kill $BGPID $FLPID $DWPID 2>/dev/null' EXIT INT TERM

times=""; last=0; last_counted=0
/usr/bin/log stream --style compact --predicate 'process == "opendirectoryd" AND eventMessage CONTAINS "Failed SecureToken authentication" AND eventMessage CONTAINS "console domain"' |
while read -r line; do
  is_lockscreen_fail "$line" || continue   # lock screen only, no background checks
  ev=$(event_epoch "$line")        # time of the event (not of processing)
  sleep $SETTLE                    # give the poller time to mark opening/waking
  lid=$(lid_state); [ "$lid" = closed ] && date +%s > "$LID"
  hb=$(cat "$HB" 2>/dev/null || echo 0)
  lid_at=$(cat "$LID" 2>/dev/null || echo 0)
  disp=$(cat "$DISP" 2>/dev/null || echo awake)
  kill -0 $DWPID 2>/dev/null || log "WARNING display-watch.py not running (display protection off)"

  if reason=$(ignore_reason "$ev" "$hb" "$lid" "$lid_at" "$last_counted" $WAKE_GRACE $LID_GRACE $BURST "$disp"); then
    log "ignored ($reason)"; continue
  fi

  # Screen locked? Otherwise ignore (unlocked = you are working)
  [ "$(lock_state)" = locked ] || continue

  now=$ev
  last_counted=$now
  # shellcheck disable=SC2086
  times=$(prune_times "$now" $WINDOW $times)
  n=$(echo "$times" | wc -w | tr -d ' ')
  log "lock-screen failed attempt $n/$THRESH"
  if [ "$n" -ge $THRESH ] && [ $((now-last)) -ge $COOLDOWN ]; then
    last=$now; times=""
    "$DIR/intruder-snap.sh" &
  fi
done
