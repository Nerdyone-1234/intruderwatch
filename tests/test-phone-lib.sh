#!/bin/bash
# Tests fuer mac/phone-lib.sh – ausfuehren: bash tests/test-phone-lib.sh
# Handy-Verbindung: zuerst WLAN-adb (PHONE_WIFI), USB nur als Notfall.
# adb und Port-Check sind Attrappen (kein echtes Handy noetig).
cd "$(dirname "$0")/.." || exit 1
export IW_CONFIG=/dev/null   # eigene config.sh nicht in Tests laden
. mac/phone-lib.sh
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (erwartet '$2', bekam '$3')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PHONE_WIFI=10.0.0.5:5555; PHONE_USB=SERIAL1; PHONE_PORT=5555

# Zustand der Attrappe in Dateien (phone_target laeuft in $(...) = Subshell).
# WIFI: device|offline|none  PORT: open|closed  USB: device|none  CAN_CONNECT: 1|0
setup(){
  echo "$1" > "$TMP/wifi"; echo "$2" > "$TMP/port"; echo "$3" > "$TMP/usb"
  echo "${4:-1}" > "$TMP/can_connect"; : > "$TMP/calls"
}
calls(){ tr '\n' ' ' < "$TMP/calls" | sed 's/ $//'; }
ph_state(){
  case "$1" in
    "$PHONE_WIFI") [ "$(cat "$TMP/wifi")" != none ] && cat "$TMP/wifi" ;;
    "$PHONE_USB")  [ "$(cat "$TMP/usb")" = device ] && echo device ;;
  esac
}
ph_port_open(){ echo "port $1 $2" >> "$TMP/calls"; [ "$(cat "$TMP/port")" = open ]; }
ph_connect(){
  echo "connect $1" >> "$TMP/calls"
  [ "$(cat "$TMP/can_connect")" = 1 ] && [ "$(cat "$TMP/port")" = open ] && echo device > "$TMP/wifi"
}
ph_disconnect(){ echo "disconnect $1" >> "$TMP/calls"; }
ph_tcpip(){
  echo "tcpip $1 $2" >> "$TMP/calls"
  [ "$(cat "$TMP/usb")" = device ] && echo open > "$TMP/port"
}
ph_settle(){ :; }
ph_nap(){ :; }

# --- phone_target ---------------------------------------------------------

# 1) WLAN schon verbunden -> WLAN, kein neuer Verbindungsaufbau
setup device closed none; t=$(phone_target); rc=$?
check "WLAN verbunden -> rc 0" 0 $rc
check "WLAN verbunden -> WLAN-Ziel" "$PHONE_WIFI" "$t"
check "WLAN verbunden -> kein connect" "" "$(calls)"

# 2) WLAN nicht verbunden, Port offen -> verbinden, WLAN
setup none open none; t=$(phone_target); rc=$?
check "Port offen -> rc 0" 0 $rc
check "Port offen -> WLAN-Ziel" "$PHONE_WIFI" "$t"
check "Port offen -> Port geprueft, dann connect" "port 10.0.0.5 5555 connect $PHONE_WIFI" "$(calls)"

# 3) WLAN-Port zu (Handy neu gestartet / weg), USB da -> USB als Notfall
setup none closed device; t=$(phone_target); rc=$?
check "nur USB -> rc 0" 0 $rc
check "nur USB -> USB-Ziel" "SERIAL1" "$t"
check "nur USB -> kein connect, kein tcpip im Alarm" "port 10.0.0.5 5555" "$(calls)"

# 4) Nichts erreichbar -> rc 1, keine Ausgabe
setup none closed none; t=$(phone_target); rc=$?
check "nichts -> rc 1" 1 $rc
check "nichts -> leere Ausgabe" "" "$t"

# 5) Port offen, aber connect klappt nicht (z. B. fremdes Geraet) -> USB-Notfall
setup none open device 0; t=$(phone_target); rc=$?
check "connect scheitert + USB -> USB-Ziel" "SERIAL1" "$t"

# 6) WLAN-Eintrag "offline" (Handy war kurz weg) -> alten Eintrag trennen, neu verbinden
setup offline open none; t=$(phone_target); rc=$?
check "offline -> WLAN-Ziel nach Neuverbindung" "$PHONE_WIFI" "$t"
check "offline -> disconnect vor connect" "port 10.0.0.5 5555 disconnect $PHONE_WIFI connect $PHONE_WIFI" "$(calls)"

# --- phone_keep_wireless (Gesundheits-Check) ------------------------------

# 7) WLAN verbunden -> nichts tun, "ok"
setup device closed none; r=$(phone_keep_wireless); rc=$?
check "keep: verbunden -> rc 0" 0 $rc
check "keep: verbunden -> ok" "ok" "$r"
check "keep: verbunden -> keine Aktion" "" "$(calls)"

# 8) Port offen -> neu verbinden
setup none open none; r=$(phone_keep_wireless); rc=$?
check "keep: Port offen -> verbunden" "verbunden" "$r"

# 9) Port zu, USB da (Handy neu gestartet) -> tcpip ueber USB, dann verbinden
setup none closed device; r=$(phone_keep_wireless); rc=$?
check "keep: USB -> rc 0" 0 $rc
check "keep: USB -> per USB eingeschaltet" "per USB eingeschaltet" "$r"
check "keep: USB -> tcpip vor connect" "port 10.0.0.5 5555 tcpip SERIAL1 5555 port 10.0.0.5 5555 connect $PHONE_WIFI" "$(calls)"

# 10) Nichts erreichbar -> rc 1
setup none closed none; r=$(phone_keep_wireless); rc=$?
check "keep: nichts -> rc 1" 1 $rc
check "keep: nichts -> nicht erreichbar" "nicht erreichbar" "$r"

# 11) Ziel ohne Port (Tippfehler in PHONE_WIFI) -> Port-Check mit Standard-Port
PHONE_WIFI=10.0.0.5; setup none open none; t=$(phone_target)
check "PHONE_WIFI ohne Port -> Standard-Port" "port 10.0.0.5 5555 connect 10.0.0.5" "$(calls)"

# --- Nur-Kabel-Modus (PHONE_WIFI leer) und automatische USB-Seriennummer ----
PHONE_WIFI=""
setup none open device; t=$(phone_target); rc=$?
check "nur Kabel -> USB-Ziel" "SERIAL1" "$t"
check "nur Kabel -> kein Port-Check, kein connect" "" "$(calls)"
setup none open device; r=$(phone_keep_wireless); rc=$?
check "nur Kabel + USB -> keep ok" "ok" "$r"
check "nur Kabel -> kein tcpip" "" "$(calls)"
setup none open none; r=$(phone_keep_wireless); rc=$?
check "nur Kabel ohne Geraet -> rc 1" 1 $rc

ph_first_usb(){ cat "$TMP/first_usb"; }
PHONE_USB=""; echo AUTO9 > "$TMP/first_usb"
ph_state(){ case "$1" in AUTO9) [ "$(cat "$TMP/usb")" = device ] && echo device ;; esac; }
setup none closed device; t=$(phone_target)
check "PHONE_USB leer -> erstes USB-Geraet" "AUTO9" "$t"
: > "$TMP/first_usb"; setup none closed none; t=$(phone_target); rc=$?
check "PHONE_USB leer, kein Geraet -> rc 1" 1 $rc

# --- phone_selfie (scrcpy-Kamera ueber adb, ohne Termux) -------------------
# REC: ok|fail|empty|failonce (1. Versuch scheitert, 2. klappt)  FRAME: jpeg|text|fail
setup_cam(){ echo "$1" > "$TMP/rec"; echo "$2" > "$TMP/frame"; : > "$TMP/calls"; rm -f "$TMP/s.jpg" "$TMP/s.mkv"; }
ph_scrcpy_record(){
  echo "record $1 $2" >> "$TMP/calls"
  case "$(cat "$TMP/rec")" in
    ok) echo video > "$2" ;;
    empty) : > "$2" ;;
    failonce) echo ok > "$TMP/rec"; return 1 ;;
    *) return 1 ;;
  esac
}
ph_cam_pause(){ echo "pause" >> "$TMP/calls"; }
ph_last_frame(){
  echo "frame" >> "$TMP/calls"
  case "$(cat "$TMP/frame")" in
    jpeg) printf '\xff\xd8\xff\xe0rest' > "$2" ;;
    text) echo "kein bild" > "$2" ;;
    *) return 1 ;;
  esac
}
PHONE_WIFI=10.0.0.5:5555

# 12) Aufnahme + Einzelbild ok -> rc 0, JPEG und Video da
setup_cam ok jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "selfie ok -> rc 0" 0 $rc
check "selfie ok -> JPEG da" ja "$([ -s "$TMP/s.jpg" ] && echo ja || echo nein)"
check "selfie ok -> Video bleibt (Beweis)" ja "$([ -s "$TMP/s.mkv" ] && echo ja || echo nein)"
check "selfie ok -> Ablauf" "record $PHONE_WIFI $TMP/s.mkv frame" "$(calls)"

# 13) scrcpy scheitert -> rc 1, kein Einzelbild-Versuch, kein JPEG
setup_cam fail jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "scrcpy scheitert -> rc 1" 1 $rc
check "scrcpy scheitert -> 2 Versuche, kein frame" "record $PHONE_WIFI $TMP/s.mkv pause record $PHONE_WIFI $TMP/s.mkv" "$(calls)"
check "scrcpy scheitert -> kein JPEG" nein "$([ -e "$TMP/s.jpg" ] && echo ja || echo nein)"

# 13b) 1. Versuch scheitert ("Server connection failed"), 2. klappt -> rc 0
setup_cam failonce jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "erst Fehler, dann ok -> rc 0" 0 $rc
check "erst Fehler, dann ok -> JPEG da" ja "$([ -s "$TMP/s.jpg" ] && echo ja || echo nein)"
check "erst Fehler, dann ok -> Ablauf" "record $PHONE_WIFI $TMP/s.mkv pause record $PHONE_WIFI $TMP/s.mkv frame" "$(calls)"

# 13c) PHONE_CAM_TRIES=1 -> kein zweiter Versuch
PHONE_CAM_TRIES=1; setup_cam fail jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"
check "1 Versuch erlaubt -> nur 1 record" "record $PHONE_WIFI $TMP/s.mkv" "$(calls)"
PHONE_CAM_TRIES=2

# 14) leeres Video -> rc 1
setup_cam empty jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "leeres Video -> rc 1" 1 $rc

# 15) Einzelbild ist kein JPEG -> rc 1, Datei entfernt
setup_cam ok text; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "kein JPEG -> rc 1" 1 $rc
check "kein JPEG -> Datei entfernt" nein "$([ -e "$TMP/s.jpg" ] && echo ja || echo nein)"

# 16) ffmpeg scheitert -> rc 1
setup_cam ok fail; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "ffmpeg scheitert -> rc 1" 1 $rc

echo "phone-lib: $pass ok, $fail fehlgeschlagen"
[ "$fail" -eq 0 ]
