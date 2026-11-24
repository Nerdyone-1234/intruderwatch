#!/bin/bash
# Tests fuer mac/last_location.py – ausfuehren: bash tests/test-last-location.sh
# Liest den letzten bekannten Standort aus `adb shell dumpsys location`
# (funktioniert ohne App-Berechtigung, auch wenn Termux:API im Hintergrund blockiert ist).
cd "$(dirname "$0")/.." || exit 1
PY=${PY:-python3}
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (erwartet '$2', bekam '$3')"; fi; }
field(){ "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], ""))' "$1"; }

DUMP='    network provider:
      last location=Location[network 52.520008,13.404954 hAcc=15.102 et=+14h41m6s985ms alt=237.0 vAcc=1.0]
    fused provider:
      last location=Location[fused 52.520008,13.404954 hAcc=100.0 et=+14h43m33s948ms alt=237.0]
    gps provider:
      last location=Location[gps 52.520100,13.405100 hAcc=4.133994 et=+3h16m4s509ms alt=240.7]'
UPTIME=53371.87   # = 14h49m31s

# 1) Neuester Eintrag gewinnt (fused, et 14h43m33s) -> Alter 358 s
out=$(echo "$DUMP" | "$PY" mac/last_location.py "$UPTIME"); rc=$?
check "rc 0 bei Treffern" 0 $rc
check "neuester Anbieter" fused "$(echo "$out" | field provider)"
check "Breite" 52.520008 "$(echo "$out" | field latitude)"
check "Laenge" 13.404954 "$(echo "$out" | field longitude)"
check "Genauigkeit" 100.0 "$(echo "$out" | field accuracy)"
check "Alter in s" 358 "$(echo "$out" | field age_s)"
check "Quelle markiert" dumpsys "$(echo "$out" | field source)"

# 2) Gleich alt -> genauerer Eintrag gewinnt
D2='last location=Location[fused 1.0,2.0 hAcc=50.0 et=+1h0m0s0ms]
last location=Location[gps 1.5,2.5 hAcc=5.0 et=+1h0m0s0ms]'
out=$(echo "$D2" | "$PY" mac/last_location.py 3700)
check "gleich alt -> genauer (gps)" gps "$(echo "$out" | field provider)"
check "Alter 100 s" 100 "$(echo "$out" | field age_s)"

# 3) Tage und negative Koordinaten
D3='last location=Location[network -33.8688,-151.2093 hAcc=20.0 et=+2d3h4m5s6ms]'
out=$(echo "$D3" | "$PY" mac/last_location.py 183845.006)
check "negative Breite" -33.8688 "$(echo "$out" | field latitude)"
check "negative Laenge" -151.2093 "$(echo "$out" | field longitude)"
check "Tage im et -> Alter 0" 0 "$(echo "$out" | field age_s)"

# 4) Kein Standort -> rc 1, keine Ausgabe
out=$(echo "    gps provider:
      last location=null" | "$PY" mac/last_location.py 100); rc=$?
check "kein Standort -> rc 1" 1 $rc
check "kein Standort -> leer" "" "$out"

# 5) Kaputte Uptime -> Alter leer, Standort trotzdem
out=$(echo "$D2" | "$PY" mac/last_location.py kaputt); rc=$?
check "kaputte Uptime -> rc 0" 0 $rc
check "kaputte Uptime -> Alter leer" "" "$(echo "$out" | field age_s)"

echo "last-location: $pass ok, $fail fehlgeschlagen"
[ "$fail" -eq 0 ]
