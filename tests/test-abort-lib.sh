#!/bin/bash
# Tests for mac/abort-lib.sh – run: bash tests/test-abort-lib.sh
# Flow: locked -> wait until unlocked (or lid closed / display off / timeout);
# unlocked -> popup, the correct secret answer stops the shutdown.
# Clock, lock, lid, display and popup are fakes (no real window).
cd "$(dirname "$0")/.." || exit 1
. mac/abort-lib.sh
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SECRET_FILE="$TMP/secret.txt"; echo "Penguin" > "$SECRET_FILE"
ABORT_LOCK_TIMEOUT=60; ABORT_ANSWER_TIMEOUT=60

# Fakes. Clock and counter live in FILES because ab_ask runs in $(...) (subshell).
# UNLOCK_AT = unlocked from then on; ANSWERS = popup answers in order
setup(){ echo 1000 > "$TMP/now"; echo 0 > "$TMP/asked"; UNLOCK_AT=${1:-999999}; LID=${2:-open}; DISP=${3:-awake}; ANSWERS=("${@:4}"); }
ab_now(){ cat "$TMP/now"; }
tick(){ echo $(( $(cat "$TMP/now") + $1 )) > "$TMP/now"; }
ab_sleep(){ tick 1; }
ab_locked(){ [ "$(ab_now)" -lt "$UNLOCK_AT" ]; }
ab_lid_closed(){ [ "$LID" = closed ]; }
ab_display_off(){ [ "$DISP" = asleep ]; }
ab_ask(){ # $1 = seconds until timeout; each answer "costs" 5 s, empty = timeout
  local n; n=$(( $(cat "$TMP/asked") + 1 )); echo "$n" > "$TMP/asked"
  local a="${ANSWERS[$((n - 1))]}"
  if [ -z "$a" ]; then tick "$1"; else tick 5; fi
  echo "$a"
}
asked(){ cat "$TMP/asked"; }
run(){ why=$(wait_for_abort); rc=$?; }

# 1) Nobody unlocks -> shut down after ABORT_LOCK_TIMEOUT, no popup
setup; run
check "stays locked -> shut down (rc 1)" 1 $rc
check "locked -> no popup" 0 "$(asked)"

# 2) Unlocked + correct answer -> cancel
setup 1010 open awake "Penguin"; run
check "unlocked + correct -> rc 0" 0 $rc
check "reason secret answer" "secret answer" "$why"
check "popup only after unlocking, once" 1 "$(asked)"

# 3) Case and spaces don't matter
setup 1010 open awake " pEnGuIn "; run
check "answer normalized" 0 $rc

# 4) Unlocked + wrong, then correct -> popup repeated, cancel
setup 1010 open awake "wrong" "Penguin"; run
check "wrong then correct -> rc 0" 0 $rc
check "popup twice" 2 "$(asked)"

# 5) Unlocked but no answer (timeout) -> shut down
setup 1010 open awake ""; run
check "unlocked without answer -> rc 1" 1 $rc

# 6) Unlocked + always wrong -> shut down after ABORT_ANSWER_TIMEOUT
setup 1010 open awake wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong wrong; run
check "always wrong -> rc 1" 1 $rc

# 7) Lid closed while locked -> cancel (nobody can type)
setup 999999 closed; run
check "lid closed -> rc 0" 0 $rc
check "reason lid closed" "lid closed" "$why"

# 8) Display off while locked -> cancel (nobody at the Mac)
setup 999999 open asleep; run
check "display off -> rc 0" 0 $rc
check "reason display off" "display off" "$why"

# 9) No secret answer set up -> unlocking is enough
rm -f "$SECRET_FILE"; setup 1010; run
check "without secret.txt: unlocking is enough" 0 $rc
check "reason unlocked" "unlocked (no secret answer set up)" "$why"
check "without secret.txt: no popup" 0 "$(asked)"

echo "abort-lib: $pass ok, $fail failed"; [ $fail -eq 0 ]
