#!/bin/bash
# Turn IntruderWatch completely OFF or ON and report it
# (macOS notification + Telegram; if the network is blocked, Telegram is sent later).
#   intruderwatch-switch.sh off|on|status
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
DIR="$HOME/Library/IntruderWatch"
LABEL="de.intruderwatch"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RETRY_EVERY=60          # seconds between resend attempts while the watcher is off
RETRY_FOR=$((24*3600))  # keep resending for at most this long
log(){ echo "$(date '+%F %T') $*" >> "$DIR/watch.log"; }
# shellcheck source=telegram-lib.sh
. "$DIR/telegram-lib.sh"

notify_mac(){ osascript -e "display notification \"$1\" with title \"IntruderWatch\"" >/dev/null 2>&1; }

is_running(){ launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

# launchctl bootout/bootstrap work asynchronously -> wait up to WAIT_MAX s for the state.
WAIT_MAX=10
wait_for(){ # $1 = on|off
  local i
  for i in $(seq 1 $WAIT_MAX); do
    if is_running; then [ "$1" = on ] && return 0; else [ "$1" = off ] && return 0; fi
    sleep 1
  done
  return 1
}

# Send to Telegram; if that fails and the watcher is off (otherwise it resends),
# run our own resend loop in the background.
tell(){
  tg_text_or_queue "$1" && return 0
  is_running && return 0
  nohup bash -c '. "$1/telegram-lib.sh"; end=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -lt $end ]; do
      tg_flush_queue
      [ -z "$(find "$TG_QUEUE" -mindepth 1 -maxdepth 1 -type d ! -name '"'"'.*'"'"' 2>/dev/null)" ] && exit 0
      sleep $3
    done' _ "$DIR" "$RETRY_FOR" "$RETRY_EVERY" >/dev/null 2>&1 &
  return 1
}

host(){ scutil --get ComputerName 2>/dev/null || hostname; }

case "$1" in
  off)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    launchctl disable "$DOMAIN/$LABEL"            # stays off after restart/login too
    pkill -f "$DIR/intruder-snap.sh" 2>/dev/null  # cancel a running alarm/shutdown
    pkill -f "$DIR/intruder-watch.sh" 2>/dev/null
    if ! wait_for off; then
      notify_mac "Turning off FAILED"; log "switch: off FAILED"; exit 1
    fi
    log "switch: IntruderWatch OFF"
    if tell "🔕 IntruderWatch was turned OFF
$(date '+%F %T') – $(host) / $(whoami)"; then
      notify_mac "IntruderWatch is OFF. Telegram notified."
    else
      notify_mac "IntruderWatch is OFF. Telegram will be sent once the network is back."
    fi
    ;;
  on)
    launchctl enable "$DOMAIN/$LABEL"
    is_running || launchctl bootstrap "$DOMAIN" "$PLIST"
    if ! wait_for on; then
      notify_mac "Turning on FAILED"; log "switch: on FAILED"; exit 1
    fi
    log "switch: IntruderWatch ON"
    tell "🔔 IntruderWatch is ON again
$(date '+%F %T') – $(host) / $(whoami)"
    notify_mac "IntruderWatch is ON."
    ;;
  status)
    if is_running; then echo on; else echo off; fi
    ;;
  *)
    echo "Usage: $0 off|on|status" >&2; exit 2
    ;;
esac
