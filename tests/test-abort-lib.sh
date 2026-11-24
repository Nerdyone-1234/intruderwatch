#!/bin/bash
# Tests fuer mac/abort-lib.sh – ausfuehren: bash tests/test-abort-lib.sh
# Ablauf: gesperrt -> warten bis entsperrt (oder Deckel zu / Display aus / Timeout);
# entsperrt -> Popup, richtige Geheimantwort stoppt das Herunterfahren.
# Uhr, Sperre, Deckel, Display und Popup sind Attrappen (kein echtes Fenster).
cd "$(dirname "$0")/.." || exit 1
. mac/abort-lib.sh
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (erwartet '$2', bekam '$3')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SECRET_FILE="$TMP/secret.txt"; echo "Pinguin" > "$SECRET_FILE"
ABORT_LOCK_TIMEOUT=60; ABORT_ANSWER_TIMEOUT=60

# Attrappen. Uhr und Zaehler liegen in DATEIEN, weil ab_ask in $(...) (Subshell) laeuft.
# UNLOCK_AT = ab wann entsperrt; ANSWERS = Popup-Antworten der Reihe nach
setup(){ echo 1000 > "$TMP/now"; echo 0 > "$TMP/asked"; UNLOCK_AT=${1:-999999}; LID=${2:-open}; DISP=${3:-awake}; ANSWERS=("${@:4}"); }
ab_now(){ cat "$TMP/now"; }
tick(){ echo $(( $(cat "$TMP/now") + $1 )) > "$TMP/now"; }
ab_sleep(){ tick 1; }
ab_locked(){ [ "$(ab_now)" -lt "$UNLOCK_AT" ]; }
ab_lid_closed(){ [ "$LID" = closed ]; }
ab_display_off(){ [ "$DISP" = asleep ]; }
ab_ask(){ # $1 = Sekunden bis Timeout; jede Antwort "kostet" 5 s, leer = Timeout
  local n; n=$(( $(cat "$TMP/asked") + 1 )); echo "$n" > "$TMP/asked"
  local a="${ANSWERS[$((n - 1))]}"
  if [ -z "$a" ]; then tick "$1"; else tick 5; fi
  echo "$a"
}
asked(){ cat "$TMP/asked"; }
run(){ why=$(wait_for_abort); rc=$?; }

# 1) Niemand entsperrt -> nach ABORT_LOCK_TIMEOUT herunterfahren, kein Popup
setup; run
check "gesperrt bleibt -> herunterfahren (rc 1)" 1 $rc
check "gesperrt -> kein Popup" 0 "$(asked)"

# 2) Entsperrt + richtige Antwort -> abbrechen
setup 1010 open awake "Pinguin"; run
check "entsperrt + richtig -> rc 0" 0 $rc
check "Grund Geheimantwort" "Geheimantwort" "$why"
check "Popup erst nach Entsperren, 1x" 1 "$(asked)"

# 3) Gross/klein + Leerzeichen egal
setup 1010 open awake " pInGuIn "; run
check "Antwort normalisiert" 0 $rc

# 4) Entsperrt + falsch, dann richtig -> Popup wiederholt, abbrechen
setup 1010 open awake "falsch" "Pinguin"; run
check "falsch dann richtig -> rc 0" 0 $rc
check "Popup 2x" 2 "$(asked)"

# 5) Entsperrt, aber keine Antwort (Timeout) -> herunterfahren
setup 1010 open awake ""; run
check "entsperrt ohne Antwort -> rc 1" 1 $rc

# 6) Entsperrt + immer falsch -> nach ABORT_ANSWER_TIMEOUT herunterfahren
setup 1010 open awake falsch falsch falsch falsch falsch falsch falsch falsch falsch falsch falsch falsch falsch; run
check "immer falsch -> rc 1" 1 $rc

# 7) Deckel zu waehrend gesperrt -> abbrechen (niemand kann tippen)
setup 999999 closed; run
check "Deckel zu -> rc 0" 0 $rc
check "Grund Deckel zu" "Deckel zu" "$why"

# 8) Display aus waehrend gesperrt -> abbrechen (niemand am Mac)
setup 999999 open asleep; run
check "Display aus -> rc 0" 0 $rc
check "Grund Display aus" "Display aus" "$why"

# 9) Keine Geheimantwort eingerichtet -> Entsperren reicht
rm -f "$SECRET_FILE"; setup 1010; run
check "ohne secret.txt: Entsperren reicht" 0 $rc
check "Grund entsperrt" "entsperrt (keine Geheimantwort eingerichtet)" "$why"
check "ohne secret.txt: kein Popup" 0 "$(asked)"

echo "$pass ok, $fail fehlgeschlagen"; [ $fail -eq 0 ]
