#!/bin/bash
# Tests for mac/watch-lib.sh – run: bash tests/test-watch-lib.sh
cd "$(dirname "$0")/.." || exit 1
. mac/watch-lib.sh
fail=0; pass=0
check(){ # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi
}
N=10000 # "now"
# ignore_reason now hb lid lid_at last_counted WAKE_GRACE LID_GRACE BURST
check "lid closed -> ignore"        "lid closed"     "$(ignore_reason $N $N closed 0 0 15 30 3)"
check "lid closed 5 s ago -> ignore" "lid just moved" "$(ignore_reason $N $N open $((N-5)) 0 15 30 3)"
check "after wake -> ignore"        "just woke up"   "$(ignore_reason $N $((N-60)) open 0 0 15 30 3)"
check "duplicate entry -> ignore"   "duplicate entry" "$(ignore_reason $N $N open 0 $((N-1)) 15 30 3)"
ignore_reason $N $N open $((N-31)) $((N-10)) 15 30 3 >/dev/null; check "real attempt -> count" 1 $?
check "prune keeps window" "9950 10000" "$(prune_times $N 120 9000 9950)"
check "prune empty"        "10000"      "$(prune_times $N 120)"
s=$(lid_state); case "$s" in open|closed) r=ok;; *) r=$s;; esac; check "lid_state returns open/closed" ok "$r"
# event_epoch: time from the log line instead of processing time (processing is serial + delayed)
L="2026-11-23 16:02:01.133 E  opendirectoryd[391:6efb] Authentication failed for <private>: ODErrorCredentialsInvalid"
check "event_epoch reads log time" "$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-23 16:02:01' +%s)" "$(event_epoch "$L")"
check "event_epoch falls back on garbage" 1 "$( [ "$(event_epoch 'garbage')" -ge $(( $(date +%s) - 2 )) ] && echo 1 || echo 0)"

# lid_mark: when does the grace period restart? (closed, woke up, opened)
check "lid closed -> mark"     mark "$(lid_mark 100 102 open closed 10)"
check "lid opened -> mark"     mark "$(lid_mark 100 102 closed open 10)"
check "woke up (gap) -> mark"  mark "$(lid_mark 100 5000 open open 10)"
check "normally open -> nothing" "" "$(lid_mark 100 102 open open 10)"

# Grace period counts from opening: a burst 3 s after opening is ignored
check "3 s after opening -> ignore" "lid just moved" "$(ignore_reason $N $N open $((N-3)) 0 15 10 2)"
check "event before mark -> ignore" "lid just moved" "$(ignore_reason $N $N open $((N+1)) 0 15 10 2)"
# Burst by log time: entries in the same/next second = one attempt
check "1 s later -> duplicate" "duplicate entry" "$(ignore_reason $N $N open 0 $((N-1)) 15 10 2)"
ignore_reason $N $N open 0 $((N-2)) 15 10 2 >/dev/null; check "2 s later -> real attempt" 1 $?

# Incident 16:13: lid opened, wrong password 3 s later -> must COUNT with LID_GRACE=2
ignore_reason $N $N open $((N-3)) 0 15 2 2 >/dev/null; check "3 s after opening counts (grace 2)" 1 $?
check "entry while lid closed (before mark) -> ignore" "lid just moved" "$(ignore_reason $N $N open $((N+2)) 0 15 2 2)"

# Incident 16:26: display went off (screen lock, lid open) -> macOS' own entries
check "display off -> ignore" "display off" "$(ignore_reason $N $N open 0 0 15 2 2 asleep)"
ignore_reason $N $N open 0 0 15 2 2 awake >/dev/null; check "display on -> counts" 1 $?
ignore_reason $N $N open 0 0 15 2 2 >/dev/null; check "no display info -> counts (backwards compatible)" 1 $?

# is_lockscreen_fail: only the lock screen ("console domain") counts, background checks ("other domain") don't
C='2026-11-23 17:16:51.871 E  opendirectoryd[393:7ab71] [com.apple.opendirectoryd:auth] Failed SecureToken authentication for 6704BB47 console domain: invalid credentials'
O='2026-11-23 18:52:15.942 E  opendirectoryd[393:bdb0f] [com.apple.opendirectoryd:auth] Failed SecureToken authentication for 6704BB47 other domain: invalid credentials'
A='2026-11-23 18:52:16.127 E  opendirectoryd[393:bdb0f] [com.apple.opendirectoryd:auth] Authentication failed for <private> (6704BB47): ODErrorCredentialsInvalid'
is_lockscreen_fail "$C"; check "console domain -> counts" 0 $?
is_lockscreen_fail "$O"; check "other domain (background app) -> ignore" 1 $?
is_lockscreen_fail "$A"; check "line without domain -> ignore" 1 $?

echo "watch-lib: $pass ok, $fail failed"; [ $fail -eq 0 ]
