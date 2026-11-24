#!/bin/bash
# Decision logic for intruder-watch.sh (separate so it can be tested).
# All functions are pure: inputs as arguments, result via exit code/stdout.

# Is the lid closed right now? Prints "closed" or "open".
lid_state(){
  if ioreg -r -k AppleClamshellState -d 1 2>/dev/null | grep -q '"AppleClamshellState" = Yes'; then
    echo closed
  else
    echo open
  fi
}

# Event time from the log line ("2026-11-23 16:02:01.133 E ..."), fallback: now.
# Important because lines are processed serially and delayed (SETTLE): otherwise a
# burst from the same second would be spread over several seconds.
event_epoch(){
  local ts="${1:0:19}" e
  e=$(date -j -f '%Y-%m-%d %H:%M:%S' "$ts" +%s 2>/dev/null) && [ -n "$e" ] && { echo "$e"; return; }
  date +%s
}

# Is the log line a wrong password at the lock screen? Exit 0 = yes.
# Lock screen/login = "console domain". Apps and background services that check the
# password (e.g. right after locking with a stale password) log "other domain".
is_lockscreen_fail(){
  case "$1" in *"Failed SecureToken authentication"*"console domain"*) return 0;; esac
  return 1
}

# Should the lid grace period restart? Prints "mark" or nothing.
#   $1 last_poll  $2 now  $3 lid_before  $4 lid_now  $5 max_gap (s)
# mark when: lid closed, just opened, or a poll gap (= the Mac was asleep).
lid_mark(){
  local prev=$1 now=$2 was=$3 is=$4 gap=$5
  if [ "$is" = closed ] || [ "$was" = closed ] || [ $((now - prev)) -gt "$gap" ]; then echo mark; fi
}

# Should a failure be ignored? Exit 0 = ignore, prints the reason.
#   $1 now  $2 heartbeat  $3 lid_now (open|closed)  $4 last_mark (epoch, 0 = never)
#   $5 last_counted_attempt (epoch)  $6 WAKE_GRACE  $7 LID_GRACE  $8 BURST
#   $9 display (awake|asleep, optional). With the display off nobody can type a
#      password (a key press only wakes the display) -> macOS' own entries on
#      locking / display off. "$4" also includes display changes (display-watch.py).
ignore_reason(){
  local now=$1 hb=$2 lid=$3 lid_closed_at=$4 last_counted=$5
  local wake_grace=$6 lid_grace=$7 burst=$8 display=${9:-awake}
  if [ "$lid" = closed ]; then echo "lid closed"; return 0; fi
  if [ "$display" = asleep ]; then echo "display off"; return 0; fi
  if [ $((now - lid_closed_at)) -le "$lid_grace" ]; then echo "lid just moved"; return 0; fi
  if [ $((now - hb)) -gt "$wake_grace" ]; then echo "just woke up"; return 0; fi
  # macOS often logs one attempt several times in the same second -> count only once
  if [ $((now - last_counted)) -lt "$burst" ]; then echo "duplicate entry"; return 0; fi
  return 1
}

# Keeps only timestamps within the window and appends now.
#   $1 now  $2 window  $3.. previous timestamps   -> prints the new list
prune_times(){
  local now=$1 window=$2 out="" t
  shift 2
  for t in "$@" "$now"; do
    [ $((now - t)) -le "$window" ] && out="$out $t"
  done
  echo "${out# }"
}
