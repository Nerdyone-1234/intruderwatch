#!/bin/bash
# Tests fuer mac/health-lib.sh – ausfuehren: bash tests/test-health-lib.sh
cd "$(dirname "$0")/.." || exit 1
. mac/health-lib.sh
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (erwartet '$2', bekam '$3')"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/alert"

# should_alert: gleiche Meldung hoechstens alle HEALTH_REPEAT s, neue Meldung sofort
HEALTH_REPEAT=21600
should_alert "$STATE" "A fehlt" 1000; check "erste Meldung -> senden" 0 $?
should_alert "$STATE" "A fehlt" 2000; check "gleiche Meldung bald -> nicht" 1 $?
should_alert "$STATE" "B fehlt" 2100; check "andere Meldung -> senden" 0 $?
should_alert "$STATE" "B fehlt" $((2100 + 21600)); check "gleiche nach 6 h -> senden" 0 $?
should_alert "$STATE" "" 30000; check "keine Probleme -> nicht senden" 1 $?
check "keine Probleme -> Zustand geloescht (naechstes Problem sofort)" 0 "$( [ -s "$STATE" ] && echo 1 || echo 0)"

# queue_stuck: wartende Eintraege aelter als Grenze zaehlen
Q="$TMP/queue"; mkdir -p "$Q/neu" "$Q/alt" "$Q/.failed/x" "$Q/.tmp-y"
touch -t 202001010000 "$Q/alt"
check "1 alter Eintrag (versteckte ignoriert)" 1 "$(queue_stuck "$Q" 60)"
check "fehlgeschlagene zaehlen" 1 "$(queue_failed "$Q")"
check "leere/fehlende Queue -> 0" 0 "$(queue_stuck "$TMP/gibtsnicht" 60)"

# hb_stale: Heartbeat aelter als Grenze
echo 1000 > "$TMP/hb"
hb_stale "$TMP/hb" 1010 30; check "frischer Heartbeat -> ok" 1 $?
hb_stale "$TMP/hb" 1100 30; check "alter Heartbeat -> veraltet" 0 $?
hb_stale "$TMP/fehlt" 1100 30; check "fehlender Heartbeat -> veraltet" 0 $?

echo "$pass ok, $fail fehlgeschlagen"; [ $fail -eq 0 ]
