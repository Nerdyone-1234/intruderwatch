#!/bin/bash
# Phone connection via adb (used by intruder-snap.sh and intruder-health.sh).
#
# Settings in ~/Library/IntruderWatch/config.sh (template mac/config.example.sh):
#   PHONE_WIFI = IP:port for Wi-Fi adb (via `adb tcpip 5555`). Empty = cable only (USB).
#   PHONE_USB  = USB serial. Empty = first device connected via USB.
# With PHONE_WIFI, Wi-Fi is tried first and USB is the fallback.
#
#   phone_target         -> prints the adb target (Wi-Fi first, else USB).
#                           Exit 0 = phone reachable, 1 = unreachable.
#                           NEVER runs `adb tcpip` during an alarm (it restarts adbd
#                           and would briefly drop the USB connection).
#   phone_keep_wireless  -> for the health check: keeps Wi-Fi adb alive.
#                           After a phone reboot Wi-Fi mode is off; if the cable is
#                           plugged in, it is turned back on via USB.
#                           Output: ok | connected | enabled via USB | unreachable
#   phone_selfie T F V   -> front camera photo via scrcpy (video V, last frame -> F).
#
# The ph_* functions can be replaced in tests.

IW_CONFIG="${IW_CONFIG:-$HOME/Library/IntruderWatch/config.sh}"
# shellcheck source=config.example.sh
[ -f "$IW_CONFIG" ] && . "$IW_CONFIG"
PHONE_WIFI="${PHONE_WIFI:-}"
PHONE_USB="${PHONE_USB:-}"
PHONE_PORT="${PHONE_PORT:-5555}"
PH_WAIT_TRIES="${PH_WAIT_TRIES:-6}"   # x 0.5 s waiting for "device" after connecting
# Selfie via scrcpy (camera over adb, without Termux:API – Android 16 blocks the
# camera there in the background). Works with the phone locked and shows nothing.
PHONE_CAM_ID="${PHONE_CAM_ID:-1}"          # `scrcpy --list-cameras`; usually 1 = front camera
PHONE_CAM_SECONDS="${PHONE_CAM_SECONDS:-3}" # video length; last frame = photo (exposure settled)
PHONE_CAM_MAX_WAIT="${PHONE_CAM_MAX_WAIT:-20}" # scrcpy hangs? give up after this many s
# The first scrcpy start after a pause sometimes fails ("Server connection failed")
# -> this many attempts. scrcpy output goes to PHONE_CAM_LOG (snap: alarm folder).
PHONE_CAM_TRIES="${PHONE_CAM_TRIES:-2}"
PHONE_CAM_LOG="${PHONE_CAM_LOG:-/dev/null}"

# State according to `adb devices` (device | offline | unauthorized | empty = not listed).
ph_state(){ adb devices 2>/dev/null | awk -v t="$1" '$1 == t { print $2 }'; }
# First device connected via USB (serial without ":" = not a Wi-Fi target).
ph_first_usb(){ adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" && $1 !~ /:/ { print $1; exit }'; }
# Port check with a 2 s limit, so an absent phone doesn't delay the alarm.
ph_port_open(){ nc -z -G 2 "$1" "$2" >/dev/null 2>&1; }
ph_connect(){ adb connect "$1" >/dev/null 2>&1; }
ph_disconnect(){ adb disconnect "$1" >/dev/null 2>&1; }
ph_tcpip(){ adb -s "$1" tcpip "$2" >/dev/null 2>&1; }
ph_settle(){ sleep 3; }   # after `adb tcpip`, adbd on the phone needs a moment
ph_nap(){ sleep 0.5; }

# Record camera video ($1 = adb target, $2 = video). With a time-limit watchdog,
# so a hanging scrcpy doesn't block the alarm.
ph_scrcpy_record(){
  command -v scrcpy >/dev/null || { echo "scrcpy not found" >> "$PHONE_CAM_LOG"; return 1; }
  # --force-adb-forward: tunnel Mac -> phone (adb forward) instead of adb reverse.
  scrcpy -s "$1" --video-source=camera --camera-id="$PHONE_CAM_ID" --max-size=1920 \
    --no-audio --no-playback --no-window --force-adb-forward \
    --record="$2" --time-limit="$PHONE_CAM_SECONDS" \
    </dev/null >>"$PHONE_CAM_LOG" 2>&1 &
  local pid=$! i
  for ((i = 0; i < PHONE_CAM_MAX_WAIT * 2; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return; }
    sleep 0.5
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 1
}
# Last frame of the video as JPEG ($1 = video, $2 = photo).
ph_last_frame(){ ffmpeg -loglevel error -y -sseof -0.5 -i "$1" -frames:v 1 -q:v 2 "$2" </dev/null >/dev/null 2>&1; }
ph_is_jpeg(){ [ -s "$1" ] && [ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" = ffd8ff ]; }
ph_cam_pause(){ sleep 1; }   # between two scrcpy attempts

# phone_selfie <adb-target> <photo.jpg> <video.mkv>: exit 0 = JPEG exists (video kept as evidence).
# Up to PHONE_CAM_TRIES scrcpy attempts; ffmpeg only if there is a video.
phone_selfie(){
  local try recorded=1
  for ((try = 1; try <= PHONE_CAM_TRIES; try++)); do
    [ "$try" -gt 1 ] && ph_cam_pause
    rm -f "$3"
    if ph_scrcpy_record "$1" "$3" && [ -s "$3" ]; then recorded=0; break; fi
  done
  if [ "$recorded" = 0 ] && ph_last_frame "$3" "$2" && ph_is_jpeg "$2"; then
    return 0
  fi
  rm -f "$2"
  return 1
}

_ph_host(){ echo "${PHONE_WIFI%%:*}"; }
_ph_port(){ case "$PHONE_WIFI" in *:*) echo "${PHONE_WIFI##*:}" ;; *) echo "$PHONE_PORT" ;; esac; }

_ph_wait_device(){
  local i
  for ((i = 0; i < PH_WAIT_TRIES; i++)); do
    [ "$(ph_state "$1")" = device ] && return 0
    ph_nap
  done
  return 1
}

# Connect Wi-Fi if the port is open. Exit 0 = Wi-Fi target is "device".
_ph_wifi_up(){
  [ -n "$PHONE_WIFI" ] || return 1               # cable-only mode
  local st; st=$(ph_state "$PHONE_WIFI")
  [ "$st" = device ] && return 0
  ph_port_open "$(_ph_host)" "$(_ph_port)" || return 1
  [ -n "$st" ] && ph_disconnect "$PHONE_WIFI"   # stale entry (offline etc.)
  ph_connect "$PHONE_WIFI"
  _ph_wait_device "$PHONE_WIFI"
}

# USB serial: PHONE_USB or (empty) the first USB device. Exit 0 = connected.
_ph_usb(){
  local s="${PHONE_USB:-$(ph_first_usb)}"
  [ -n "$s" ] && [ "$(ph_state "$s")" = device ] && echo "$s"
}

phone_target(){
  local usb
  if _ph_wifi_up; then echo "$PHONE_WIFI"; return 0; fi
  if usb=$(_ph_usb); then echo "$usb"; return 0; fi
  return 1
}

phone_keep_wireless(){
  local usb
  if [ -z "$PHONE_WIFI" ]; then                  # cable-only mode: nothing to keep alive
    if _ph_usb >/dev/null; then echo ok; return 0; fi
    echo "unreachable"; return 1
  fi
  if [ "$(ph_state "$PHONE_WIFI")" = device ]; then echo ok; return 0; fi
  if _ph_wifi_up; then echo connected; return 0; fi
  if usb=$(_ph_usb); then
    ph_tcpip "$usb" "$(_ph_port)"
    ph_settle
    if _ph_wifi_up; then echo "enabled via USB"; return 0; fi
  fi
  echo "unreachable"; return 1
}
