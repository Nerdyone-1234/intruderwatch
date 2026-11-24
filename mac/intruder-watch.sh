#!/bin/bash
# Loest intruder-snap.sh NUR aus, wenn jemand am GESPERRTEN, AUFGEKLAPPTEN Mac
# mehrfach das falsche Passwort eingibt. Ignoriert: entsperrte Sitzung (sudo-
# Vertipper, App-Abfragen), Zuklappen/Aufklappen (macOS loggt dabei Auth-
# Fehlschlaege) und Doppel-Eintraege desselben Versuchs.
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
THRESH=2            # echte Fehlversuche bis Ausloesung
WINDOW=120          # innerhalb dieser Sekunden
COOLDOWN=300        # danach Ruhe
WAKE_GRACE=15       # Sekunden nach Aufwachen ignorieren
LID_GRACE=2         # Sekunden nach Aufklappen/Aufwachen ignorieren. macOS schreibt
                    # eigene Fehlschlaege nur bei ZUGEKLAPPTEM Deckel (gemessen
                    # 2026-11-23); die faengt "Deckel zu" bzw. Logzeit < Markierung ab.
BURST=2             # Eintraege mit Logzeit-Abstand < BURST s = ein Versuch
SETTLE=2            # kurz warten, damit der Deckel-Zustand aktuell ist
POLL=2              # Abfrage-Intervall Heartbeat/Deckel
SLEEP_GAP=10        # Poll-Luecke groesser als das = Mac hat geschlafen
FLUSH_EVERY=60      # Sekunden: wartende Telegram-Fotos erneut senden
WARN_EVERY=3600     # Warnung "Sperr-Erkennung kaputt" hoechstens so oft
DIR="$HOME/Library/IntruderWatch"
PY=/opt/homebrew/bin/python3
HB="$DIR/.heartbeat"
LID="$DIR/.lid_closed_at"   # letzter Moment: Deckel zu/auf, aufgewacht, Display an/aus
DISP="$DIR/.display_state"  # awake|asleep, geschrieben von display-watch.py
log(){ echo "$(date '+%F %T') $*" >> "$DIR/watch.log"; }

# shellcheck source=watch-lib.sh
. "$DIR/watch-lib.sh" || { log "watch-lib.sh fehlt"; exit 1; }
# shellcheck source=telegram-lib.sh
. "$DIR/telegram-lib.sh" || { log "telegram-lib.sh fehlt"; exit 1; }

# Sperr-Erkennung pruefen. Liefert is_locked.py weder locked noch unlocked (z. B.
# pyobjc fehlt nach Python-Update), wuerde der Waechter sonst STILL nie ausloesen.
WARNF="$DIR/.last_lock_warn"   # Datei, weil lock_state in $(...) (Subshell) laeuft
lock_state(){
  local s; s=$("$PY" "$DIR/is_locked.py" 2>&1)
  case "$s" in
    locked|unlocked) echo "$s";;
    *) echo broken
       local now last; now=$(date +%s); last=$(cat "$WARNF" 2>/dev/null || echo 0)
       if [ $((now - last)) -ge $WARN_EVERY ]; then
         echo "$now" > "$WARNF"
         log "FEHLER Sperr-Erkennung kaputt: $(echo "$s" | tail -1)"
         tg_text_or_queue "⚠️ IntruderWatch: Sperr-Erkennung kaputt – Alarm loest NICHT aus.
$(echo "$s" | tail -1)
Fix: /opt/homebrew/bin/pip3 install --break-system-packages pyobjc-framework-Quartz" >/dev/null
       fi;;
  esac
}
[ "$(lock_state)" = broken ] && log "Start: Sperr-Erkennung kaputt (Telegram-Warnung gesendet)"

# Hintergrund: Heartbeat + Zeitpunkt der letzten Deckel-/Aufwach-Bewegung. Die
# Schonfrist LID_GRACE laeuft ab dem AUFKLAPPEN/AUFWACHEN, nicht ab dem letzten
# "zu" vor dem Schlafen (sonst waere sie nach langem Schlaf schon abgelaufen).
date +%s > "$HB"; date +%s > "$LID"
rmdir "$TG_QUEUE/.lock" 2>/dev/null   # verwaiste Sperre nach Absturz/Herunterfahren
( prev=$(date +%s); was=$(lid_state)
  while true; do
    now=$(date +%s); is=$(lid_state)
    [ -n "$(lid_mark "$prev" "$now" "$was" "$is" $SLEEP_GAP)" ] && echo "$now" > "$LID"
    echo "$now" > "$HB"; prev=$now; was=$is
    sleep $POLL
  done ) &
BGPID=$!
# Hintergrund: Display an/aus beobachten (macOS schreibt beim Sperren/Display-Aus
# eigene Fehlschlaege, auch bei offenem Deckel)
echo awake > "$DISP"
"$PY" "$DIR/display-watch.py" "$DIR" 2>>"$DIR/launchd.err" &
DWPID=$!
# Hintergrund: Telegram-Warteschlange nachsenden (auch direkt nach Login/Neustart)
( while true; do tg_flush_queue; sleep $FLUSH_EVERY; done ) &
FLPID=$!
trap 'kill $BGPID $FLPID $DWPID 2>/dev/null' EXIT INT TERM

times=""; last=0; last_counted=0
/usr/bin/log stream --style compact --predicate 'process == "opendirectoryd" AND eventMessage CONTAINS "Failed SecureToken authentication" AND eventMessage CONTAINS "console domain"' |
while read -r line; do
  is_lockscreen_fail "$line" || continue   # nur Sperrbildschirm, keine Hintergrund-Pruefungen
  ev=$(event_epoch "$line")        # Zeit des Ereignisses (nicht der Verarbeitung)
  sleep $SETTLE                    # Poller Zeit geben, Aufklappen/Aufwachen zu markieren
  lid=$(lid_state); [ "$lid" = closed ] && date +%s > "$LID"
  hb=$(cat "$HB" 2>/dev/null || echo 0)
  lid_at=$(cat "$LID" 2>/dev/null || echo 0)
  disp=$(cat "$DISP" 2>/dev/null || echo awake)
  kill -0 $DWPID 2>/dev/null || log "WARNUNG display-watch.py laeuft nicht (Display-Schutz aus)"

  if reason=$(ignore_reason "$ev" "$hb" "$lid" "$lid_at" "$last_counted" $WAKE_GRACE $LID_GRACE $BURST "$disp"); then
    log "ignoriert ($reason)"; continue
  fi

  # Bildschirm gesperrt? sonst ignorieren (entsperrt = du arbeitest)
  [ "$(lock_state)" = locked ] || continue

  now=$ev
  last_counted=$now
  # shellcheck disable=SC2086
  times=$(prune_times "$now" $WINDOW $times)
  n=$(echo "$times" | wc -w | tr -d ' ')
  log "Sperrbildschirm-Fehlversuch $n/$THRESH"
  if [ "$n" -ge $THRESH ] && [ $((now-last)) -ge $COOLDOWN ]; then
    last=$now; times=""
    "$DIR/intruder-snap.sh" &
  fi
done
