#!/bin/bash
# Testable helper functions for intruder-health.sh.

HEALTH_REPEAT="${HEALTH_REPEAT:-21600}"   # same warning at most every 6 h

# Should a warning be sent? $1 state file  $2 message ("" = all ok)  $3 now
# New/different message -> right away; same -> only after HEALTH_REPEAT; ok -> clear state.
should_alert(){
  local state=$1 msg=$2 now=$3 last_msg last_at
  if [ -z "$msg" ]; then rm -f "$state"; return 1; fi
  if [ -f "$state" ]; then
    last_at=$(head -1 "$state"); last_msg=$(tail -n +2 "$state")
    if [ "$last_msg" = "$msg" ] && [ $((now - last_at)) -lt "$HEALTH_REPEAT" ]; then return 1; fi
  fi
  printf "%s\n%s" "$now" "$msg" > "$state"
  return 0
}

# Number of queued entries older than $2 minutes (hidden ones ignored).
queue_stuck(){
  [ -d "$1" ] || { echo 0; return; }
  find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -mmin +"$2" | wc -l | tr -d ' '
}

# Number of permanently rejected entries.
queue_failed(){
  [ -d "$1/.failed" ] || { echo 0; return; }
  find "$1/.failed" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}

# Heartbeat stale? $1 file  $2 now  $3 max age (s). Exit 0 = stale/missing.
hb_stale(){
  local hb
  hb=$(cat "$1" 2>/dev/null) || return 0
  [ -n "$hb" ] || return 0
  [ $(( $2 - hb )) -gt "$3" ]
}
