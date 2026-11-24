#!/bin/bash
# IntruderWatch komplett AUS- oder EINschalten und Bescheid geben
# (macOS-Mitteilung + Telegram; bei blockiertem Netz wird Telegram nachgesendet).
#   intruderwatch-switch.sh off|on|status
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
DIR="$HOME/Library/IntruderWatch"
LABEL="de.intruderwatch"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RETRY_EVERY=60          # Sekunden zwischen Nachsende-Versuchen, solange der Waechter aus ist
RETRY_FOR=$((24*3600))  # so lange maximal nachsenden
log(){ echo "$(date '+%F %T') $*" >> "$DIR/watch.log"; }
# shellcheck source=telegram-lib.sh
. "$DIR/telegram-lib.sh"

notify_mac(){ osascript -e "display notification \"$1\" with title \"IntruderWatch\"" >/dev/null 2>&1; }

is_running(){ launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

# launchctl bootout/bootstrap arbeiten asynchron -> bis zu WAIT_MAX s auf Zustand warten.
WAIT_MAX=10
wait_for(){ # $1 = an|aus
  local i
  for i in $(seq 1 $WAIT_MAX); do
    if is_running; then [ "$1" = an ] && return 0; else [ "$1" = aus ] && return 0; fi
    sleep 1
  done
  return 1
}

# Telegram senden; klappt es nicht und der Waechter ist aus (er sendet sonst nach),
# laeuft im Hintergrund eine eigene Nachsende-Schleife.
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
    launchctl disable "$DOMAIN/$LABEL"          # bleibt auch nach Neustart/Login aus
    pkill -f "$DIR/intruder-snap.sh" 2>/dev/null  # laufenden Alarm/Herunterfahren abbrechen
    pkill -f "$DIR/intruder-watch.sh" 2>/dev/null
    if ! wait_for aus; then
      notify_mac "Ausschalten FEHLGESCHLAGEN"; log "switch: off FEHLGESCHLAGEN"; exit 1
    fi
    log "switch: IntruderWatch AUS"
    if tell "🔕 IntruderWatch wurde AUSGESCHALTET
$(date '+%F %T') – $(host) / $(whoami)"; then
      notify_mac "IntruderWatch ist AUS. Telegram benachrichtigt."
    else
      notify_mac "IntruderWatch ist AUS. Telegram wird nachgesendet, sobald Netz da ist."
    fi
    ;;
  on)
    launchctl enable "$DOMAIN/$LABEL"
    is_running || launchctl bootstrap "$DOMAIN" "$PLIST"
    if ! wait_for an; then
      notify_mac "Einschalten FEHLGESCHLAGEN"; log "switch: on FEHLGESCHLAGEN"; exit 1
    fi
    log "switch: IntruderWatch AN"
    tell "🔔 IntruderWatch ist wieder AN
$(date '+%F %T') – $(host) / $(whoami)"
    notify_mac "IntruderWatch ist AN."
    ;;
  status)
    if is_running; then echo an; else echo aus; fi
    ;;
  *)
    echo "Benutzung: $0 off|on|status" >&2; exit 2
    ;;
esac
