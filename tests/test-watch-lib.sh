#!/bin/bash
# Tests fuer mac/watch-lib.sh – ausfuehren: bash tests/test-watch-lib.sh
cd "$(dirname "$0")/.." || exit 1
. mac/watch-lib.sh
fail=0; pass=0
check(){ # name erwartet tatsaechlich
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (erwartet '$2', bekam '$3')"; fi
}
N=10000 # "jetzt"
# ignore_reason now hb lid lid_at last_counted WAKE_GRACE LID_GRACE BURST
check "Deckel zu -> ignorieren"        "Deckel zu"            "$(ignore_reason $N $N closed 0 0 15 30 3)"
check "Deckel vor 5s zu -> ignorieren" "Deckel gerade bewegt" "$(ignore_reason $N $N open $((N-5)) 0 15 30 3)"
check "nach Aufwachen -> ignorieren"   "gerade aufgewacht"    "$(ignore_reason $N $((N-60)) open 0 0 15 30 3)"
check "Doppel-Eintrag -> ignorieren"   "Doppel-Eintrag"       "$(ignore_reason $N $N open 0 $((N-1)) 15 30 3)"
ignore_reason $N $N open $((N-31)) $((N-10)) 15 30 3 >/dev/null; check "echter Versuch -> zaehlen" 1 $?
check "prune behaelt Fenster"    "9950 10000" "$(prune_times $N 120 9000 9950)"
check "prune leer"               "10000"      "$(prune_times $N 120)"
s=$(lid_state); case "$s" in open|closed) r=ok;; *) r=$s;; esac; check "lid_state liefert open/closed" ok "$r"
# event_epoch: Zeit aus der Logzeile statt Verarbeitungszeit (Verarbeitung ist seriell + verzoegert)
L="2026-11-23 16:02:01.133 E  opendirectoryd[391:6efb] Authentication failed for <private>: ODErrorCredentialsInvalid"
check "event_epoch liest Logzeit" "$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-11-23 16:02:01' +%s)" "$(event_epoch "$L")"
check "event_epoch Fallback bei Muell" 1 "$( [ "$(event_epoch 'muell')" -ge $(( $(date +%s) - 2 )) ] && echo 1 || echo 0)"

# lid_mark: wann beginnt die Schonfrist neu? (zu, aufgewacht, aufgeklappt)
check "Deckel zu -> mark"         mark "$(lid_mark 100 102 open closed 10)"
check "aufgeklappt -> mark"       mark "$(lid_mark 100 102 closed open 10)"
check "aufgewacht (Luecke) -> mark" mark "$(lid_mark 100 5000 open open 10)"
check "normal offen -> nichts"    ""   "$(lid_mark 100 102 open open 10)"

# Schonfrist zaehlt ab Aufklappen: Burst 3 s nach dem Oeffnen wird ignoriert
check "3 s nach Aufklappen -> ignorieren" "Deckel gerade bewegt" "$(ignore_reason $N $N open $((N-3)) 0 15 10 2)"
check "Ereignis vor Markierung -> ignorieren" "Deckel gerade bewegt" "$(ignore_reason $N $N open $((N+1)) 0 15 10 2)"
# Burst nach Logzeit: Eintraege in derselben/naechsten Sekunde = ein Versuch
check "1 s spaeter -> Doppel" "Doppel-Eintrag" "$(ignore_reason $N $N open 0 $((N-1)) 15 10 2)"
ignore_reason $N $N open 0 $((N-2)) 15 10 2 >/dev/null; check "2 s spaeter -> echter Versuch" 1 $?

# Vorfall 16:13: Lid auf, Passwort 3 s danach falsch -> muss mit LID_GRACE=2 ZAEHLEN
ignore_reason $N $N open $((N-3)) 0 15 2 2 >/dev/null; check "3 s nach Aufklappen zaehlt (Grace 2)" 1 $?
check "Eintrag bei zugeklapptem Deckel (vor Markierung) -> ignorieren" "Deckel gerade bewegt" "$(ignore_reason $N $N open $((N+2)) 0 15 2 2)"

# Vorfall 16:26: Display ging aus (Bildschirmsperre, Deckel offen) -> macOS-Eintraege
check "Display aus -> ignorieren" "Display aus" "$(ignore_reason $N $N open 0 0 15 2 2 asleep)"
ignore_reason $N $N open 0 0 15 2 2 awake >/dev/null; check "Display an -> zaehlt" 1 $?
ignore_reason $N $N open 0 0 15 2 2 >/dev/null; check "ohne Display-Info -> zaehlt (alt kompatibel)" 1 $?

# is_lockscreen_fail: nur Sperrbildschirm ("console domain") zaehlt, Hintergrund-Pruefungen ("other domain") nicht
C='2026-11-23 17:16:51.871 E  opendirectoryd[393:7ab71] [com.apple.opendirectoryd:auth] Failed SecureToken authentication for 6704BB47 console domain: invalid credentials'
O='2026-11-23 18:52:15.942 E  opendirectoryd[393:bdb0f] [com.apple.opendirectoryd:auth] Failed SecureToken authentication for 6704BB47 other domain: invalid credentials'
A='2026-11-23 18:52:16.127 E  opendirectoryd[393:bdb0f] [com.apple.opendirectoryd:auth] Authentication failed for <private> (6704BB47): ODErrorCredentialsInvalid'
is_lockscreen_fail "$C"; check "console domain -> zaehlt" 0 $?
is_lockscreen_fail "$O"; check "other domain (Hintergrund-App) -> ignorieren" 1 $?
is_lockscreen_fail "$A"; check "Zeile ohne Domain -> ignorieren" 1 $?

echo "$pass ok, $fail fehlgeschlagen"; [ $fail -eq 0 ]
