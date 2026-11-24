#!/bin/bash
# Regular health check for IntruderWatch (launchd job de.intruderwatch.health,
# every 30 min). Checks the service, background processes, heartbeat, lock detection,
# Telegram config, installed files and the queue. If the watcher is stopped, it is
# restarted. If a problem remains, a Telegram warning is sent (same warning at most
# every 6 h); once everything is ok again, an all-clear.
# Turned off on purpose (IntruderWatch OFF.app) -> the check stays silent.
#   intruder-health.sh            normal run (launchd)
#   intruder-health.sh --report   show status, send nothing, restart nothing
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
DIR="$HOME/Library/IntruderWatch"
LABEL="de.intruderwatch"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PY=/opt/homebrew/bin/python3
STATE="$DIR/.health_alert"
HB_MAX=60          # the heartbeat may be at most this old (s)
QUEUE_MAX_MIN=60   # Telegram entries waiting longer than this -> report
RECHECK=10         # check again before restarting/warning (e.g. right after waking)
REPORT=0; [ "$1" = --report ] && REPORT=1
log(){ [ $REPORT = 1 ] || echo "$(date '+%F %T') HEALTH: $*" >> "$DIR/watch.log"; }

# shellcheck source=telegram-lib.sh
. "$DIR/telegram-lib.sh" || { echo "telegram-lib.sh missing"; exit 1; }
# shellcheck source=health-lib.sh
. "$DIR/health-lib.sh" || { echo "health-lib.sh missing"; exit 1; }
# shellcheck source=phone-lib.sh
. "$DIR/phone-lib.sh" || { echo "phone-lib.sh missing"; exit 1; }

is_disabled(){ launchctl print-disabled "$DOMAIN" 2>/dev/null | grep -q "\"$LABEL\" => disabled"; }
is_loaded(){ launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

# Prints one line per problem. "SERVICE:" = fixable by a restart.
check_all(){
  local f
  is_loaded || echo "SERVICE: watcher not loaded"
  pgrep -f "$DIR/intruder-watch.sh" >/dev/null || echo "SERVICE: intruder-watch.sh not running"
  pgrep -f 'log stream --style compact --predicate process == "opendirectoryd"' >/dev/null || echo "SERVICE: log monitoring (log stream) not running"
  pgrep -f "$DIR/display-watch.py" >/dev/null || echo "SERVICE: display-watch.py not running"
  hb_stale "$DIR/.heartbeat" "$(date +%s)" $HB_MAX && echo "SERVICE: heartbeat stale"
  case "$("$PY" "$DIR/is_locked.py" 2>/dev/null)" in
    locked|unlocked) ;;
    *) echo "lock detection broken (pyobjc?) – fix: /opt/homebrew/bin/pip3 install --break-system-packages pyobjc-framework-Quartz";;
  esac
  [ -n "$(tg_credentials)" ] || echo "Telegram config missing/broken ($TG_CONFIG)"
  for f in intruder-watch.sh intruder-snap.sh watch-lib.sh telegram-lib.sh abort-lib.sh phone-lib.sh is_locked.py last_location.py display-watch.py; do
    [ -s "$DIR/$f" ] || echo "file missing: $f"
  done
  [ -d "$DIR/MacCamSnap.app" ] || echo "MacCamSnap.app missing (no webcam photo)"
  local n; n=$(queue_stuck "$TG_QUEUE" $QUEUE_MAX_MIN)
  [ "$n" -gt 0 ] && echo "Telegram: $n entry/entries waiting > ${QUEUE_MAX_MIN} min (network blocked?)"
  n=$(queue_failed "$TG_QUEUE")
  [ "$n" -gt 0 ] && echo "Telegram: $n entry/entries permanently rejected (see $TG_QUEUE/.failed)"
}

if is_disabled; then
  [ $REPORT = 1 ] && echo "IntruderWatch is turned OFF on purpose – no check."
  exit 0
fi

# Keep phone Wi-Fi adb alive (turn it back on via USB after a phone reboot).
# Not a problem entry: the phone is often away, a warning would just be noise.
# Log only on a change, so there isn't a line every 30 min.
if [ $REPORT = 1 ]; then
  ph=$(phone_target) && echo "Phone: reachable ($ph)" || echo "Phone: unreachable (Wi-Fi ${PHONE_WIFI:-off})"
else
  ph=$(phone_keep_wireless)
  case "$ph" in ok|unreachable) ;; *) log "phone Wi-Fi adb: $ph ($PHONE_WIFI)";; esac
fi

problems=$(check_all)
if [ -n "$problems" ] && [ $REPORT = 0 ]; then
  sleep $RECHECK; problems=$(check_all)          # e.g. just woke up
fi

healed=""
if [ $REPORT = 0 ] && echo "$problems" | grep -q '^SERVICE:'; then
  log "restarting the watcher ($(echo "$problems" | grep '^SERVICE:' | tr '\n' ';'))"
  if is_loaded; then launchctl kickstart -k "$DOMAIN/$LABEL"; else launchctl bootstrap "$DOMAIN" "$PLIST"; fi
  sleep $RECHECK; problems=$(check_all)
  echo "$problems" | grep -q '^SERVICE:' || healed=1
fi

if [ $REPORT = 1 ]; then
  if [ -z "$problems" ]; then echo "✅ IntruderWatch: all ok"; exit 0; fi
  echo "⚠️ IntruderWatch: problems"; echo "$problems" | sed 's/^/- /'; exit 1
fi

had_alert=0; [ -f "$STATE" ] && had_alert=1
msg=$(echo "$problems" | sed '/^$/d' | sort)
if should_alert "$STATE" "$msg" "$(date +%s)"; then
  log "PROBLEM: $(echo "$msg" | tr '\n' ';')"
  tg_text_or_queue "⚠️ IntruderWatch check: problem
$(echo "$msg" | sed 's/^SERVICE: //; s/^/- /')
$(date '+%F %T')" >/dev/null
elif [ -z "$msg" ]; then
  if [ -n "$healed" ]; then
    log "watcher was stopped and has been restarted – now ok"
    tg_text_or_queue "🔧 IntruderWatch was stopped and has been restarted automatically – now ok.
$(date '+%F %T')" >/dev/null
  elif [ $had_alert = 1 ]; then
    log "ok again"
    tg_text_or_queue "✅ IntruderWatch check: all ok again
$(date '+%F %T')" >/dev/null
  fi
fi
exit 0
