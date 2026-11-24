#!/bin/bash
# Regelmaessiger Gesundheits-Check fuer IntruderWatch (launchd-Job de.intruderwatch.health,
# alle 30 min). Prueft Dienst, Hintergrundprozesse, Heartbeat, Sperr-Erkennung, Telegram-
# Config, installierte Dateien und die Warteschlange. Ist der Waechter gestoppt, wird er
# neu gestartet. Bleibt ein Problem, kommt eine Telegram-Warnung (gleiche Warnung max.
# alle 6 h); ist alles wieder ok, eine Entwarnung.
# Absichtlich ausgeschaltet (IntruderWatch AUS.app) -> Check bleibt still.
#   intruder-health.sh            normaler Lauf (launchd)
#   intruder-health.sh --report   Status anzeigen, nichts senden, nichts neu starten
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
DIR="$HOME/Library/IntruderWatch"
LABEL="de.intruderwatch"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PY=/opt/homebrew/bin/python3
STATE="$DIR/.health_alert"
HB_MAX=60          # Heartbeat darf hoechstens so alt sein (s)
QUEUE_MAX_MIN=60   # Telegram-Eintraege laenger als das wartend -> melden
RECHECK=10         # vor Neustart/Warnung nochmal pruefen (z. B. direkt nach Aufwachen)
REPORT=0; [ "$1" = --report ] && REPORT=1
log(){ [ $REPORT = 1 ] || echo "$(date '+%F %T') HEALTH: $*" >> "$DIR/watch.log"; }

# shellcheck source=telegram-lib.sh
. "$DIR/telegram-lib.sh" || { echo "telegram-lib.sh fehlt"; exit 1; }
# shellcheck source=health-lib.sh
. "$DIR/health-lib.sh" || { echo "health-lib.sh fehlt"; exit 1; }
# shellcheck source=phone-lib.sh
. "$DIR/phone-lib.sh" || { echo "phone-lib.sh fehlt"; exit 1; }

is_disabled(){ launchctl print-disabled "$DOMAIN" 2>/dev/null | grep -q "\"$LABEL\" => disabled"; }
is_loaded(){ launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

# Gibt je Problem eine Zeile aus. "DIENST:" = durch Neustart behebbar.
check_all(){
  local f
  is_loaded || echo "DIENST: Waechter nicht geladen"
  pgrep -f "$DIR/intruder-watch.sh" >/dev/null || echo "DIENST: intruder-watch.sh laeuft nicht"
  pgrep -f 'log stream --style compact --predicate process == "opendirectoryd"' >/dev/null || echo "DIENST: Log-Ueberwachung (log stream) laeuft nicht"
  pgrep -f "$DIR/display-watch.py" >/dev/null || echo "DIENST: display-watch.py laeuft nicht"
  hb_stale "$DIR/.heartbeat" "$(date +%s)" $HB_MAX && echo "DIENST: Heartbeat veraltet"
  case "$("$PY" "$DIR/is_locked.py" 2>/dev/null)" in
    locked|unlocked) ;;
    *) echo "Sperr-Erkennung kaputt (pyobjc?) – Fix: /opt/homebrew/bin/pip3 install --break-system-packages pyobjc-framework-Quartz";;
  esac
  [ -n "$(tg_credentials)" ] || echo "Telegram-Config fehlt/kaputt ($TG_CONFIG)"
  for f in intruder-watch.sh intruder-snap.sh watch-lib.sh telegram-lib.sh abort-lib.sh phone-lib.sh is_locked.py last_location.py display-watch.py; do
    [ -s "$DIR/$f" ] || echo "Datei fehlt: $f"
  done
  [ -d "$DIR/MacCamSnap.app" ] || echo "MacCamSnap.app fehlt (kein Webcam-Foto)"
  local n; n=$(queue_stuck "$TG_QUEUE" $QUEUE_MAX_MIN)
  [ "$n" -gt 0 ] && echo "Telegram: $n Eintrag/Eintraege warten seit > ${QUEUE_MAX_MIN} min (Netz blockiert?)"
  n=$(queue_failed "$TG_QUEUE")
  [ "$n" -gt 0 ] && echo "Telegram: $n Eintrag/Eintraege dauerhaft abgelehnt (siehe $TG_QUEUE/.failed)"
}

if is_disabled; then
  [ $REPORT = 1 ] && echo "IntruderWatch ist absichtlich AUS – kein Check."
  exit 0
fi

# Handy-WLAN-adb am Leben halten (nach Handy-Neustart per USB wieder einschalten).
# Kein Problem-Eintrag: das Handy ist oft unterwegs, eine Warnung waere nur Laerm.
# Log nur bei einer Aenderung, damit nicht alle 30 min eine Zeile entsteht.
if [ $REPORT = 1 ]; then
  ph=$(phone_target) && echo "Handy: erreichbar ($ph)" || echo "Handy: nicht erreichbar (WLAN $PHONE_WIFI)"
else
  ph=$(phone_keep_wireless)
  case "$ph" in ok|"nicht erreichbar") ;; *) log "Handy-WLAN-adb: $ph ($PHONE_WIFI)";; esac
fi

problems=$(check_all)
if [ -n "$problems" ] && [ $REPORT = 0 ]; then
  sleep $RECHECK; problems=$(check_all)          # z. B. gerade aufgewacht
fi

healed=""
if [ $REPORT = 0 ] && echo "$problems" | grep -q '^DIENST:'; then
  log "Neustart des Waechters ($(echo "$problems" | grep '^DIENST:' | tr '\n' ';'))"
  if is_loaded; then launchctl kickstart -k "$DOMAIN/$LABEL"; else launchctl bootstrap "$DOMAIN" "$PLIST"; fi
  sleep $RECHECK; problems=$(check_all)
  echo "$problems" | grep -q '^DIENST:' || healed=1
fi

if [ $REPORT = 1 ]; then
  if [ -z "$problems" ]; then echo "✅ IntruderWatch: alles ok"; exit 0; fi
  echo "⚠️ IntruderWatch: Probleme"; echo "$problems" | sed 's/^/- /'; exit 1
fi

had_alert=0; [ -f "$STATE" ] && had_alert=1
msg=$(echo "$problems" | sed '/^$/d' | sort)
if should_alert "$STATE" "$msg" "$(date +%s)"; then
  log "PROBLEM: $(echo "$msg" | tr '\n' ';')"
  tg_text_or_queue "⚠️ IntruderWatch-Check: Problem
$(echo "$msg" | sed 's/^DIENST: //; s/^/- /')
$(date '+%F %T')" >/dev/null
elif [ -z "$msg" ]; then
  if [ -n "$healed" ]; then
    log "Waechter war gestoppt und wurde neu gestartet – jetzt ok"
    tg_text_or_queue "🔧 IntruderWatch war gestoppt und wurde automatisch neu gestartet – jetzt ok.
$(date '+%F %T')" >/dev/null
  elif [ $had_alert = 1 ]; then
    log "wieder ok"
    tg_text_or_queue "✅ IntruderWatch-Check: wieder alles ok
$(date '+%F %T')" >/dev/null
  fi
fi
exit 0
