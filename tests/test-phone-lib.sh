#!/bin/bash
# Tests for mac/phone-lib.sh – run: bash tests/test-phone-lib.sh
# Phone connection: Wi-Fi adb first (PHONE_WIFI), USB only as fallback.
# adb and the port check are fakes (no real phone needed).
cd "$(dirname "$0")/.." || exit 1
export IW_CONFIG=/dev/null   # don't load your own config.sh in tests
. mac/phone-lib.sh
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PHONE_WIFI=10.0.0.5:5555; PHONE_USB=SERIAL1; PHONE_PORT=5555

# Fake state in files (phone_target runs in $(...) = subshell).
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

# 1) Wi-Fi already connected -> Wi-Fi, no new connection
setup device closed none; t=$(phone_target); rc=$?
check "Wi-Fi connected -> rc 0" 0 $rc
check "Wi-Fi connected -> Wi-Fi target" "$PHONE_WIFI" "$t"
check "Wi-Fi connected -> no connect" "" "$(calls)"

# 2) Wi-Fi not connected, port open -> connect, Wi-Fi
setup none open none; t=$(phone_target); rc=$?
check "port open -> rc 0" 0 $rc
check "port open -> Wi-Fi target" "$PHONE_WIFI" "$t"
check "port open -> port checked, then connect" "port 10.0.0.5 5555 connect $PHONE_WIFI" "$(calls)"

# 3) Wi-Fi port closed (phone rebooted / away), USB present -> USB fallback
setup none closed device; t=$(phone_target); rc=$?
check "USB only -> rc 0" 0 $rc
check "USB only -> USB target" "SERIAL1" "$t"
check "USB only -> no connect, no tcpip during alarm" "port 10.0.0.5 5555" "$(calls)"

# 4) Nothing reachable -> rc 1, no output
setup none closed none; t=$(phone_target); rc=$?
check "nothing -> rc 1" 1 $rc
check "nothing -> empty output" "" "$t"

# 5) Port open but connect fails (e.g. another device) -> USB fallback
setup none open device 0; t=$(phone_target); rc=$?
check "connect fails + USB -> USB target" "SERIAL1" "$t"

# 6) Wi-Fi entry "offline" (phone was briefly away) -> drop stale entry, reconnect
setup offline open none; t=$(phone_target); rc=$?
check "offline -> Wi-Fi target after reconnect" "$PHONE_WIFI" "$t"
check "offline -> disconnect before connect" "port 10.0.0.5 5555 disconnect $PHONE_WIFI connect $PHONE_WIFI" "$(calls)"

# --- phone_keep_wireless (health check) -----------------------------------

# 7) Wi-Fi connected -> do nothing, "ok"
setup device closed none; r=$(phone_keep_wireless); rc=$?
check "keep: connected -> rc 0" 0 $rc
check "keep: connected -> ok" "ok" "$r"
check "keep: connected -> no action" "" "$(calls)"

# 8) Port open -> reconnect
setup none open none; r=$(phone_keep_wireless); rc=$?
check "keep: port open -> connected" "connected" "$r"

# 9) Port closed, USB present (phone rebooted) -> tcpip over USB, then connect
setup none closed device; r=$(phone_keep_wireless); rc=$?
check "keep: USB -> rc 0" 0 $rc
check "keep: USB -> enabled via USB" "enabled via USB" "$r"
check "keep: USB -> tcpip before connect" "port 10.0.0.5 5555 tcpip SERIAL1 5555 port 10.0.0.5 5555 connect $PHONE_WIFI" "$(calls)"

# 10) Nothing reachable -> rc 1
setup none closed none; r=$(phone_keep_wireless); rc=$?
check "keep: nothing -> rc 1" 1 $rc
check "keep: nothing -> unreachable" "unreachable" "$r"

# 11) Target without port (typo in PHONE_WIFI) -> port check with default port
PHONE_WIFI=10.0.0.5; setup none open none; t=$(phone_target)
check "PHONE_WIFI without port -> default port" "port 10.0.0.5 5555 connect 10.0.0.5" "$(calls)"

# --- Cable-only mode (PHONE_WIFI empty) and automatic USB serial -------------
PHONE_WIFI=""
setup none open device; t=$(phone_target); rc=$?
check "cable only -> USB target" "SERIAL1" "$t"
check "cable only -> no port check, no connect" "" "$(calls)"
setup none open device; r=$(phone_keep_wireless); rc=$?
check "cable only + USB -> keep ok" "ok" "$r"
check "cable only -> no tcpip" "" "$(calls)"
setup none open none; r=$(phone_keep_wireless); rc=$?
check "cable only without device -> rc 1" 1 $rc

ph_first_usb(){ cat "$TMP/first_usb"; }
PHONE_USB=""; echo AUTO9 > "$TMP/first_usb"
ph_state(){ case "$1" in AUTO9) [ "$(cat "$TMP/usb")" = device ] && echo device ;; esac; }
setup none closed device; t=$(phone_target)
check "PHONE_USB empty -> first USB device" "AUTO9" "$t"
: > "$TMP/first_usb"; setup none closed none; t=$(phone_target); rc=$?
check "PHONE_USB empty, no device -> rc 1" 1 $rc

# --- phone_selfie (scrcpy camera over adb, without Termux) -----------------
# REC: ok|fail|empty|failonce (1st attempt fails, 2nd works)  FRAME: jpeg|text|fail
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
    text) echo "no image" > "$2" ;;
    *) return 1 ;;
  esac
}
PHONE_WIFI=10.0.0.5:5555

# 12) Recording + frame ok -> rc 0, JPEG and video exist
setup_cam ok jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "selfie ok -> rc 0" 0 $rc
check "selfie ok -> JPEG exists" yes "$([ -s "$TMP/s.jpg" ] && echo yes || echo no)"
check "selfie ok -> video kept (evidence)" yes "$([ -s "$TMP/s.mkv" ] && echo yes || echo no)"
check "selfie ok -> sequence" "record $PHONE_WIFI $TMP/s.mkv frame" "$(calls)"

# 13) scrcpy fails -> rc 1, no frame attempt, no JPEG
setup_cam fail jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "scrcpy fails -> rc 1" 1 $rc
check "scrcpy fails -> 2 attempts, no frame" "record $PHONE_WIFI $TMP/s.mkv pause record $PHONE_WIFI $TMP/s.mkv" "$(calls)"
check "scrcpy fails -> no JPEG" no "$([ -e "$TMP/s.jpg" ] && echo yes || echo no)"

# 13b) 1st attempt fails ("Server connection failed"), 2nd works -> rc 0
setup_cam failonce jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "first error, then ok -> rc 0" 0 $rc
check "first error, then ok -> JPEG exists" yes "$([ -s "$TMP/s.jpg" ] && echo yes || echo no)"
check "first error, then ok -> sequence" "record $PHONE_WIFI $TMP/s.mkv pause record $PHONE_WIFI $TMP/s.mkv frame" "$(calls)"

# 13c) PHONE_CAM_TRIES=1 -> no second attempt
PHONE_CAM_TRIES=1; setup_cam fail jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"
check "1 attempt allowed -> only 1 record" "record $PHONE_WIFI $TMP/s.mkv" "$(calls)"
PHONE_CAM_TRIES=2

# 14) empty video -> rc 1
setup_cam empty jpeg; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "empty video -> rc 1" 1 $rc

# 15) frame is not a JPEG -> rc 1, file removed
setup_cam ok text; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "not a JPEG -> rc 1" 1 $rc
check "not a JPEG -> file removed" no "$([ -e "$TMP/s.jpg" ] && echo yes || echo no)"

# 16) ffmpeg fails -> rc 1
setup_cam ok fail; phone_selfie "$PHONE_WIFI" "$TMP/s.jpg" "$TMP/s.mkv"; rc=$?
check "ffmpeg fails -> rc 1" 1 $rc

echo "phone-lib: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
