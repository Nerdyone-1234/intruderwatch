#!/bin/bash
# Testbare Hilfsfunktionen fuer intruder-health.sh.

HEALTH_REPEAT="${HEALTH_REPEAT:-21600}"   # gleiche Warnung hoechstens alle 6 h

# Soll eine Warnung gesendet werden? $1 Zustandsdatei  $2 Meldung ("" = alles ok)  $3 jetzt
# Neue/andere Meldung -> sofort; gleiche -> erst nach HEALTH_REPEAT; ok -> Zustand loeschen.
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

# Anzahl wartender Eintraege, die aelter als $2 Minuten sind (versteckte ignoriert).
queue_stuck(){
  [ -d "$1" ] || { echo 0; return; }
  find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -mmin +"$2" | wc -l | tr -d ' '
}

# Anzahl dauerhaft abgelehnter Eintraege.
queue_failed(){
  [ -d "$1/.failed" ] || { echo 0; return; }
  find "$1/.failed" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}

# Heartbeat veraltet? $1 Datei  $2 jetzt  $3 max. Alter (s). Exit 0 = veraltet/fehlt.
hb_stale(){
  local hb
  hb=$(cat "$1" 2>/dev/null) || return 0
  [ -n "$hb" ] || return 0
  [ $(( $2 - hb )) -gt "$3" ]
}
