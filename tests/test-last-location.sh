#!/bin/bash
# Tests for mac/last_location.py – run: bash tests/test-last-location.sh
# Reads the last known location from `adb shell dumpsys location`
# (works without app permission, even when Termux:API is blocked in the background).
cd "$(dirname "$0")/.." || exit 1
PY=${PY:-python3}
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }
field(){ "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], ""))' "$1"; }

DUMP='    network provider:
      last location=Location[network 52.520008,13.404954 hAcc=15.102 et=+14h41m6s985ms alt=237.0 vAcc=1.0]
    fused provider:
      last location=Location[fused 52.520008,13.404954 hAcc=100.0 et=+14h43m33s948ms alt=237.0]
    gps provider:
      last location=Location[gps 52.520100,13.405100 hAcc=4.133994 et=+3h16m4s509ms alt=240.7]'
UPTIME=53371.87   # = 14h49m31s

# 1) Newest entry wins (fused, et 14h43m33s) -> age 358 s
out=$(echo "$DUMP" | "$PY" mac/last_location.py "$UPTIME"); rc=$?
check "rc 0 on matches" 0 $rc
check "newest provider" fused "$(echo "$out" | field provider)"
check "latitude" 52.520008 "$(echo "$out" | field latitude)"
check "longitude" 13.404954 "$(echo "$out" | field longitude)"
check "accuracy" 100.0 "$(echo "$out" | field accuracy)"
check "age in s" 358 "$(echo "$out" | field age_s)"
check "source marked" dumpsys "$(echo "$out" | field source)"

# 2) Same age -> more accurate entry wins
D2='last location=Location[fused 1.0,2.0 hAcc=50.0 et=+1h0m0s0ms]
last location=Location[gps 1.5,2.5 hAcc=5.0 et=+1h0m0s0ms]'
out=$(echo "$D2" | "$PY" mac/last_location.py 3700)
check "same age -> more accurate (gps)" gps "$(echo "$out" | field provider)"
check "age 100 s" 100 "$(echo "$out" | field age_s)"

# 3) Days and negative coordinates
D3='last location=Location[network -33.8688,-151.2093 hAcc=20.0 et=+2d3h4m5s6ms]'
out=$(echo "$D3" | "$PY" mac/last_location.py 183845.006)
check "negative latitude" -33.8688 "$(echo "$out" | field latitude)"
check "negative longitude" -151.2093 "$(echo "$out" | field longitude)"
check "days in et -> age 0" 0 "$(echo "$out" | field age_s)"

# 4) No location -> rc 1, no output
out=$(echo "    gps provider:
      last location=null" | "$PY" mac/last_location.py 100); rc=$?
check "no location -> rc 1" 1 $rc
check "no location -> empty" "" "$out"

# 5) Broken uptime -> age empty, location still there
out=$(echo "$D2" | "$PY" mac/last_location.py broken); rc=$?
check "broken uptime -> rc 0" 0 $rc
check "broken uptime -> age empty" "" "$(echo "$out" | field age_s)"

echo "last-location: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
