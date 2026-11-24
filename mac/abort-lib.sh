#!/bin/bash
# Abbruch des Herunterfahrens nach einem Alarm (von intruder-snap.sh benutzt).
#
# Ablauf:
#   1. Mac gesperrt: warten, bis er mit dem richtigen Passwort entsperrt wird
#      (max. ABORT_LOCK_TIMEOUT s). Deckel zu oder Display aus -> abbrechen
#      (niemand am Mac; schuetzt vor Fehlalarmen). Timeout -> herunterfahren.
#   2. Mac entsperrt: Popup (ohne Fragetext, verdeckte Eingabe) fragt die
#      Geheimantwort aus SECRET_FILE ab. Richtig -> abbrechen. Falsch -> erneut
#      fragen. Keine richtige Antwort binnen ABORT_ANSWER_TIMEOUT s -> herunterfahren.
#   Ohne SECRET_FILE reicht das Entsperren.
# Das Popup erscheint erst NACH dem Entsperren – auf dem Sperrbildschirm waere es
# unsichtbar (macOS zeigt keine Fenster ueber dem Sperrbildschirm).
#
# wait_for_abort: Exit 0 = NICHT herunterfahren (Grund auf stdout), 1 = herunterfahren.
# Die ab_*-Funktionen sind in Tests ersetzbar.

ABORT_LOCK_TIMEOUT="${ABORT_LOCK_TIMEOUT:-60}"
ABORT_ANSWER_TIMEOUT="${ABORT_ANSWER_TIMEOUT:-60}"
SECRET_FILE="${SECRET_FILE:-$HOME/Library/IntruderWatch/secret.txt}"
AB_DIR="${AB_DIR:-$HOME/Library/IntruderWatch}"
AB_PY="${AB_PY:-/opt/homebrew/bin/python3}"

ab_now(){ date +%s; }
ab_sleep(){ sleep 1; }
ab_locked(){ [ "$("$AB_PY" "$AB_DIR/is_locked.py" 2>/dev/null)" != unlocked ]; }
ab_lid_closed(){ ioreg -r -k AppleClamshellState -d 1 2>/dev/null | grep -q '"AppleClamshellState" = Yes'; }
ab_display_off(){ [ "$(cat "$AB_DIR/.display_state" 2>/dev/null)" = asleep ]; }

# Zeigt das Popup bis zu $1 Sekunden; gibt die Eingabe aus (leer bei Timeout).
ab_ask(){
  osascript 2>/dev/null <<OSA
try
  tell me to activate
  set r to display dialog "" default answer "" with hidden answer buttons {"OK"} default button "OK" giving up after $1
  return text returned of r
on error
  return ""
end try
OSA
}

ab_norm(){ printf "%s" "$1" | tr -d " \r\n" | tr "[:upper:]" "[:lower:]"; }

wait_for_abort(){
  local want="" deadline left ans
  [ -s "$SECRET_FILE" ] && want=$(ab_norm "$(cat "$SECRET_FILE")")

  deadline=$(( $(ab_now) + ABORT_LOCK_TIMEOUT ))
  while ab_locked; do
    if ab_lid_closed; then echo "Deckel zu"; return 0; fi
    if ab_display_off; then echo "Display aus"; return 0; fi
    [ "$(ab_now)" -ge "$deadline" ] && return 1
    ab_sleep
  done

  if [ -z "$want" ]; then echo "entsperrt (keine Geheimantwort eingerichtet)"; return 0; fi

  deadline=$(( $(ab_now) + ABORT_ANSWER_TIMEOUT ))
  while left=$(( deadline - $(ab_now) )); [ "$left" -gt 0 ]; do
    ans=$(ab_norm "$(ab_ask "$left")")
    if [ -n "$ans" ] && [ "$ans" = "$want" ]; then echo "Geheimantwort"; return 0; fi
  done
  return 1
}
