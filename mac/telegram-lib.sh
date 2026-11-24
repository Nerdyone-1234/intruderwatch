#!/bin/bash
# Telegram sending with a queue: if sendPhoto/sendMessage fails only TEMPORARILY
# (Wi-Fi blocks Telegram, offline, 429/5xx), the entry is stored in TG_QUEUE and
# sent later by tg_flush_queue (intruder-watch.sh calls it regularly). PERMANENT
# rejections (4xx, not a JPEG) are not queued or are moved to TG_QUEUE/.failed,
# so they don't clog the queue.
# Token/chat are NEVER stored in the queue; they are read fresh when sending.
#
# Return values of the send functions: 0 = sent, 1 = temporary, 2 = permanent.

IW_CONFIG="${IW_CONFIG:-$HOME/Library/IntruderWatch/config.sh}"
# shellcheck source=config.example.sh
[ -f "$IW_CONFIG" ] && . "$IW_CONFIG"
# JSON {"token": ..., "allowed_chat_id": ...}; path configurable in config.sh.
TG_CONFIG="${TG_CONFIG:-$HOME/Library/IntruderWatch/telegram.json}"
TG_QUEUE="${TG_QUEUE:-$HOME/Library/IntruderWatch/queue}"
TG_TIMEOUT="${TG_TIMEOUT:-30}"
TG_MAX_AGE_DAYS="${TG_MAX_AGE_DAYS:-30}"   # drop older entries
TG_LOCK_STALE="${TG_LOCK_STALE:-300}"      # a lock older than this (s) is stale
TG_DELAY_TAG="⏳ Sent late (Wi-Fi/network was blocked)"

tg_log(){ declare -F log >/dev/null && log "$*"; return 0; }

# Reads token and chat from the config. Prints "token chat" or nothing.
tg_credentials(){
  [ -f "$TG_CONFIG" ] || return 1
  /usr/bin/python3 - "$TG_CONFIG" <<'PY' 2>/dev/null
import json, sys
c = json.load(open(sys.argv[1]))
t, ch = c.get("token", ""), str(c.get("allowed_chat_id", ""))
if t and ch: print(t, ch)
PY
}

# HTTP calls to Telegram (replaceable in tests).
tg_post(){ # $1 token $2 chat $3 photo $4 text
  curl -s -m "$TG_TIMEOUT" -F "chat_id=$2" -F "photo=@$3" --form-string "caption=$4" \
    "https://api.telegram.org/bot$1/sendPhoto"
}
tg_post_text(){ # $1 token $2 chat $3 text
  curl -s -m "$TG_TIMEOUT" --form-string "chat_id=$2" --form-string "text=$3" \
    "https://api.telegram.org/bot$1/sendMessage"
}

# Is the file a JPEG (signature FF D8 FF)? Protects against error messages as "photo".
tg_is_jpeg(){ [ -s "$1" ] && [ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" = ffd8ff ]; }

# Classify the Telegram response -> 0 ok, 2 permanent (4xx except 429), else 1.
tg_classify(){
  case "$1" in
    *'"ok":true'*) return 0;;
    *'"error_code":429'*) return 1;;
    *'"error_code":4'[0-9][0-9]*) return 2;;
    *) return 1;;
  esac
}

tg_send_text(){ # $1 text
  local creds resp
  creds=$(tg_credentials) || return 1
  [ -n "$creds" ] || return 1
  # shellcheck disable=SC2086
  set -- $creds "$1"
  resp=$(tg_post_text "$1" "$2" "$3" 2>/dev/null) || return 1
  tg_classify "$resp"
}

tg_send_photo(){ # $1 photo $2 text
  local photo=$1 caption=$2 creds resp
  tg_is_jpeg "$photo" || return 2
  creds=$(tg_credentials) || return 1
  [ -n "$creds" ] || return 1
  # shellcheck disable=SC2086
  set -- $creds
  resp=$(tg_post "$1" "$2" "$photo" "$caption" 2>/dev/null) || return 1
  tg_classify "$resp"
}

# Creates an entry ATOMICALLY: write it completely in .tmp-* first, then rename.
# So tg_flush_queue never sees a half-written entry. $1 text  $2 photo (optional)
tg_enqueue(){
  local caption=$1 photo=$2 tmp
  mkdir -p "$TG_QUEUE" && chmod 700 "$TG_QUEUE" || return 1
  tmp=$(mktemp -d "$TG_QUEUE/.tmp-XXXXXX") || return 1
  if [ -n "$photo" ] && ! cp "$photo" "$tmp/photo.jpg"; then rm -rf "$tmp"; return 1; fi
  printf "%s" "$caption" > "$tmp/caption.txt" &&
    mv "$tmp" "$TG_QUEUE/$(date +%Y%m%d-%H%M%S)-$$-$RANDOM" || { rm -rf "$tmp"; return 1; }
}

# Send a photo; temporary error -> queue. Exit 0 sent, 1 queued, 2 rejected.
tg_send_or_queue(){
  tg_send_photo "$1" "$2"; local rc=$?
  case $rc in
    0) return 0;;
    2) tg_log "telegram: photo permanently rejected (not a JPEG/4xx) - not queued: $1"; return 2;;
  esac
  tg_enqueue "$2" "$1" && tg_log "telegram blocked/failed -> queued"
  return 1
}

# Send text; temporary error -> queue. Exit codes like tg_send_or_queue.
tg_text_or_queue(){
  tg_send_text "$1"; local rc=$?
  case $rc in
    0) return 0;;
    2) tg_log "telegram: text permanently rejected (4xx)"; return 2;;
  esac
  tg_enqueue "$1" && tg_log "telegram text -> queued"
  return 1
}

# Take the lock; a stale one (older than TG_LOCK_STALE) is taken over.
tg_lock(){
  local lock="$TG_QUEUE/.lock" age
  mkdir "$lock" 2>/dev/null && return 0
  age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || date +%s) ))
  [ "$age" -gt "$TG_LOCK_STALE" ] || return 1
  tg_log "queue: removed stale lock ($age s)"
  rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null
}

# Sends all finished entries (oldest first). Temporary error -> stop (network
# gone, otherwise every entry runs into the timeout). Permanent error -> move
# to .failed and continue.
tg_flush_queue(){
  local entry text rc sent=0
  [ -d "$TG_QUEUE" ] || return 0
  tg_lock || return 0
  find "$TG_QUEUE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -mtime +"$TG_MAX_AGE_DAYS" -exec rm -rf {} + 2>/dev/null
  for entry in $(find "$TG_QUEUE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort); do
    text="$TG_DELAY_TAG
$(cat "$entry/caption.txt" 2>/dev/null)"
    if [ -e "$entry/photo.jpg" ]; then
      tg_send_photo "$entry/photo.jpg" "$text"; rc=$?
    elif [ -s "$entry/caption.txt" ]; then
      tg_send_text "$text"; rc=$?
    else
      rc=2
    fi
    case $rc in
      0) rm -rf "$entry"; sent=$((sent+1));;
      2) mkdir -p "$TG_QUEUE/.failed" && mv "$entry" "$TG_QUEUE/.failed/"
         tg_log "queue: entry permanently rejected -> .failed/$(basename "$entry")";;
      *) break;;
    esac
  done
  rmdir "$TG_QUEUE/.lock" 2>/dev/null
  [ $sent -gt 0 ] && tg_log "queue: $sent entry/entries sent late"
  return 0
}
