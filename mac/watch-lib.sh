#!/bin/bash
# Entscheidungslogik fuer intruder-watch.sh (separat, damit sie testbar ist).
# Alle Funktionen sind rein: Eingaben als Argumente, Ergebnis per Exit-Code/stdout.

# Ist der Deckel gerade zu? Gibt "closed" oder "open" aus.
lid_state(){
  if ioreg -r -k AppleClamshellState -d 1 2>/dev/null | grep -q '"AppleClamshellState" = Yes'; then
    echo closed
  else
    echo open
  fi
}

# Zeit des Ereignisses aus der Logzeile ("2026-11-23 16:02:01.133 E ..."), Fallback: jetzt.
# Wichtig, weil die Zeilen seriell und verzoegert (SETTLE) verarbeitet werden: ein
# Burst aus derselben Sekunde wuerde sonst auf mehrere Sekunden verteilt.
event_epoch(){
  local ts="${1:0:19}" e
  e=$(date -j -f '%Y-%m-%d %H:%M:%S' "$ts" +%s 2>/dev/null) && [ -n "$e" ] && { echo "$e"; return; }
  date +%s
}

# Ist die Logzeile ein falsches Passwort am Sperrbildschirm? Exit 0 = ja.
# Sperrbildschirm/Login = "console domain". Apps und Hintergrunddienste, die das Passwort
# pruefen (z. B. direkt nach dem Sperren mit veraltetem Passwort), loggen "other domain".
is_lockscreen_fail(){
  case "$1" in *"Failed SecureToken authentication"*"console domain"*) return 0;; esac
  return 1
}

# Soll die Deckel-Schonfrist neu beginnen? Ausgabe "mark" oder nichts.
#   $1 letzter_poll  $2 jetzt  $3 deckel_vorher  $4 deckel_jetzt  $5 max_luecke (s)
# mark bei: Deckel zu, gerade aufgeklappt, oder Poll-Luecke (= Mac hat geschlafen).
lid_mark(){
  local prev=$1 now=$2 was=$3 is=$4 gap=$5
  if [ "$is" = closed ] || [ "$was" = closed ] || [ $((now - prev)) -gt "$gap" ]; then echo mark; fi
}

# Soll ein Fehlschlag ignoriert werden? Exit 0 = ignorieren, gibt den Grund aus.
#   $1 now  $2 heartbeat  $3 lid_now (open|closed)  $4 zuletzt_zu (epoch, 0 = nie)
#   $5 letzter_gezaehlter_versuch (epoch)  $6 WAKE_GRACE  $7 LID_GRACE  $8 BURST
#   $9 display (awake|asleep, optional). Bei ausgeschaltetem Display kann niemand ein
#      Passwort tippen (Tastendruck weckt erst das Display) -> macOS-eigene Eintraege
#      beim Sperren / Display-Aus. "$4" enthaelt auch Display-Wechsel (display-watch.py).
ignore_reason(){
  local now=$1 hb=$2 lid=$3 lid_closed_at=$4 last_counted=$5
  local wake_grace=$6 lid_grace=$7 burst=$8 display=${9:-awake}
  if [ "$lid" = closed ]; then echo "Deckel zu"; return 0; fi
  if [ "$display" = asleep ]; then echo "Display aus"; return 0; fi
  if [ $((now - lid_closed_at)) -le "$lid_grace" ]; then echo "Deckel gerade bewegt"; return 0; fi
  if [ $((now - hb)) -gt "$wake_grace" ]; then echo "gerade aufgewacht"; return 0; fi
  # macOS loggt einen Versuch oft mehrfach in derselben Sekunde -> nur einmal zaehlen
  if [ $((now - last_counted)) -lt "$burst" ]; then echo "Doppel-Eintrag"; return 0; fi
  return 1
}

# Behaelt nur Zeitstempel innerhalb des Fensters und haengt now an.
#   $1 now  $2 window  $3.. bisherige Zeitstempel   -> gibt neue Liste aus
prune_times(){
  local now=$1 window=$2 out="" t
  shift 2
  for t in "$@" "$now"; do
    [ $((now - t)) -le "$window" ] && out="$out $t"
  done
  echo "${out# }"
}
