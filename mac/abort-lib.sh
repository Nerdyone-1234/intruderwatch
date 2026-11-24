#!/bin/bash
# Cancelling the shutdown after an alarm (used by intruder-snap.sh).
#
# Flow:
#   1. Mac locked: wait until it is unlocked with the correct password
#      (max. ABORT_LOCK_TIMEOUT s). Lid closed or display off -> cancel
#      (nobody at the Mac; protects against false alarms). Timeout -> shut down.
#   2. Mac unlocked: a popup (no question text, hidden input) asks for the
#      secret answer from SECRET_FILE. Correct -> cancel. Wrong -> ask again.
#      No correct answer within ABORT_ANSWER_TIMEOUT s -> shut down.
#   Without SECRET_FILE, unlocking is enough.
# The popup only appears AFTER unlocking – on the lock screen it would be
# invisible (macOS shows no windows above the lock screen).
#
# wait_for_abort: exit 0 = do NOT shut down (reason on stdout), 1 = shut down.
# The ab_* functions can be replaced in tests.

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

# Shows the popup for up to $1 seconds; prints the input (empty on timeout).
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
    if ab_lid_closed; then echo "lid closed"; return 0; fi
    if ab_display_off; then echo "display off"; return 0; fi
    [ "$(ab_now)" -ge "$deadline" ] && return 1
    ab_sleep
  done

  if [ -z "$want" ]; then echo "unlocked (no secret answer set up)"; return 0; fi

  deadline=$(( $(ab_now) + ABORT_ANSWER_TIMEOUT ))
  while left=$(( deadline - $(ab_now) )); [ "$left" -gt 0 ]; do
    ans=$(ab_norm "$(ab_ask "$left")")
    if [ -n "$ans" ] && [ "$ans" = "$want" ]; then echo "secret answer"; return 0; fi
  done
  return 1
}
