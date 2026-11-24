#!/bin/bash
# Tests for mac/health-lib.sh – run: bash tests/test-health-lib.sh
cd "$(dirname "$0")/.." || exit 1
. mac/health-lib.sh
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/alert"

# should_alert: same message at most every HEALTH_REPEAT s, new message right away
HEALTH_REPEAT=21600
should_alert "$STATE" "A missing" 1000; check "first message -> send" 0 $?
should_alert "$STATE" "A missing" 2000; check "same message soon -> don't" 1 $?
should_alert "$STATE" "B missing" 2100; check "different message -> send" 0 $?
should_alert "$STATE" "B missing" $((2100 + 21600)); check "same after 6 h -> send" 0 $?
should_alert "$STATE" "" 30000; check "no problems -> don't send" 1 $?
check "no problems -> state cleared (next problem right away)" 0 "$( [ -s "$STATE" ] && echo 1 || echo 0)"

# queue_stuck: count queued entries older than the limit
Q="$TMP/queue"; mkdir -p "$Q/new" "$Q/old" "$Q/.failed/x" "$Q/.tmp-y"
touch -t 202001010000 "$Q/old"
check "1 old entry (hidden ones ignored)" 1 "$(queue_stuck "$Q" 60)"
check "failed entries counted" 1 "$(queue_failed "$Q")"
check "empty/missing queue -> 0" 0 "$(queue_stuck "$TMP/missing" 60)"

# hb_stale: heartbeat older than the limit
echo 1000 > "$TMP/hb"
hb_stale "$TMP/hb" 1010 30; check "fresh heartbeat -> ok" 1 $?
hb_stale "$TMP/hb" 1100 30; check "old heartbeat -> stale" 0 $?
hb_stale "$TMP/missing" 1100 30; check "missing heartbeat -> stale" 0 $?

echo "health-lib: $pass ok, $fail failed"; [ $fail -eq 0 ]
