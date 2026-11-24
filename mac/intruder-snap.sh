#!/bin/bash
# On a failed Mac login: photo from the phone's front camera AND the Mac webcam,
# location/metadata, Telegram alert with preview, local copies, then (optionally)
# shut the Mac down.
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
PHONE_ALBUM=/sdcard/Pictures/IntruderWatch
ENABLE_SHUTDOWN=1            # 1 = shut the Mac down after the photos, 0 = don't
SHUTDOWN_WHEN=after_capture  # after_capture (recommended) | immediate
OUT="$HOME/Pictures/Intruder/$(date +%Y-%m-%d_%H-%M-%S)"
LOG="$HOME/Library/IntruderWatch/watch.log"
TERMUX_ENV="HOME=/data/data/com.termux/files/home PREFIX=/data/data/com.termux/files/usr PATH=/data/data/com.termux/files/usr/bin LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec.so TMPDIR=/data/data/com.termux/files/usr/tmp ANDROID_DATA=/data ANDROID_ROOT=/system"
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
# shellcheck source=telegram-lib.sh
. "$HOME/Library/IntruderWatch/telegram-lib.sh"
# Cancel logic (wait for unlocking, then popup with the secret answer): see abort-lib.sh
# shellcheck source=abort-lib.sh
. "$HOME/Library/IntruderWatch/abort-lib.sh"
# Phone via Wi-Fi adb (PHONE_WIFI) or USB: see phone-lib.sh
# shellcheck source=phone-lib.sh
. "$HOME/Library/IntruderWatch/phone-lib.sh"

do_shutdown(){
  local why
  if why=$(wait_for_abort); then
    log "shutdown CANCELLED ($why)"
    # Notification only on an unlocked Mac: on the lock screen the intruder would see
    # it, and it would wake the display.
    [ "$why" != "lid closed" ] && [ "$why" != "display off" ] && osascript -e "display notification \"Shutdown cancelled\" with title \"IntruderWatch\"" >/dev/null 2>&1
    return
  fi
  log "shutting down mac (force)"
  # 1) password-less sudo (if set up)
  if sudo -n /sbin/shutdown -h now >/dev/null 2>&1; then return; fi
  # 2) fallback: kill blocking apps, then shut down
  for a in Terminal iTerm2 ghostty; do killall -9 "$a" >/dev/null 2>&1; done
  osascript -e 'tell application "System Events" to shut down' >/dev/null 2>&1
}

mkdir -p "$OUT"

# Mac webcam photo (right away, before the intruder is gone)
MAC_CAM_BUNDLE="$HOME/Library/IntruderWatch/MacCamSnap.app"
if [ -d "$MAC_CAM_BUNDLE" ]; then
  open "$MAC_CAM_BUNDLE" --args "$OUT/mac-cam.jpg" 2>>"$LOG"
  for i in 1 2 3 4 5 6 7 8; do [ -s "$OUT/mac-cam.jpg" ] && break; sleep 0.5; done
elif command -v imagesnap >/dev/null; then
  imagesnap -q -w 1.0 "$OUT/mac-cam.jpg" 2>>"$LOG"
fi
[ -s "$OUT/mac-cam.jpg" ] && log "mac-cam ok" || { rm -f "$OUT/mac-cam.jpg"; log "mac-cam FAILED (camera access?)"; }

# optional: immediate shutdown (not recommended - the upload gets cut off)
[ "$ENABLE_SHUTDOWN" = 1 ] && [ "$SHUTDOWN_WHEN" = immediate ] && { do_shutdown; }

adb start-server >/dev/null 2>&1
if ! SERIAL=$(phone_target); then
  log "phone not connected (Wi-Fi $PHONE_WIFI / USB $PHONE_USB) - Mac photo only"
else
  log "phone via $([ "$SERIAL" = "$PHONE_WIFI" ] && echo Wi-Fi || echo USB) ($SERIAL)"
  # Selfie first (the intruder is sitting at the Mac now): scrcpy camera over adb, also
  # with the phone locked. Termux:API may not use the camera in the background on Android 16.
  PHONE_CAM_LOG="$OUT/scrcpy.log" phone_selfie "$SERIAL" "$OUT/selfie.jpg" "$OUT/selfie.mkv" \
    && log "phone selfie ok (scrcpy)"
  # Termux: Wi-Fi info + location
  adb -s "$SERIAL" shell "run-as com.termux env $TERMUX_ENV /data/data/com.termux/files/usr/bin/sh /data/data/com.termux/files/home/bin/snap.sh" >/dev/null 2>&1
  adb -s "$SERIAL" exec-out run-as com.termux cat files/home/loc.json  > "$OUT/location.json"
  adb -s "$SERIAL" exec-out run-as com.termux cat files/home/wifi.json > "$OUT/phone-wifi.json"
  # Android 16 often gives Termux:API no location in the background -> read the last
  # known location via dumpsys (needs no app permission, instant).
  if ! grep -q '"latitude"' "$OUT/location.json" 2>/dev/null; then
    UPTIME=$(adb -s "$SERIAL" shell cat /proc/uptime 2>/dev/null | cut -d' ' -f1)
    if adb -s "$SERIAL" shell dumpsys location 2>/dev/null \
        | python3 "$HOME/Library/IntruderWatch/last_location.py" "$UPTIME" > "$OUT/location.tmp"; then
      mv "$OUT/location.tmp" "$OUT/location.json"; log "location: last known (dumpsys)"
    else
      rm -f "$OUT/location.tmp"; log "location: none found"
    fi
  fi
  if [ -s "$OUT/selfie.jpg" ]; then
    adb -s "$SERIAL" shell "mkdir -p $PHONE_ALBUM" >/dev/null 2>&1
    STAMP=$(date +%Y-%m-%d_%H-%M-%S)
    adb -s "$SERIAL" push "$OUT/selfie.jpg" "$PHONE_ALBUM/intruder_$STAMP.jpg" >/dev/null 2>&1
    adb -s "$SERIAL" shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://$PHONE_ALBUM/intruder_$STAMP.jpg" >/dev/null 2>&1
  else
    log "phone selfie MISSING (see $OUT/scrcpy.log)"
  fi
fi

# Read the location in ONE Python call (path as an argument, not inserted into code)
read -r LAT LON ACC AGE < <(python3 - "$OUT/location.json" <<'PY' 2>/dev/null
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
print(*(str(d.get(k, "")) or "-" for k in ("latitude", "longitude", "accuracy", "age_s")))
PY
)
[ "$LAT" = - ] && LAT=""; [ "$LON" = - ] && LON=""; [ "$ACC" = - ] && ACC=""; [ "$AGE" = - ] && AGE=""
LOC_AGE=""; [ -n "$AGE" ] && LOC_AGE=", as of $(( (AGE + 30) / 60 )) min ago"
{
  echo "mac_time: $(date '+%F %T %z')"; echo "mac_user: $(whoami)"; echo "mac_host: $(scutil --get ComputerName)"
  echo "location: $LAT, $LON  (+/- ${ACC} m${LOC_AGE})"
  echo "mac_cam: $([ -f "$OUT/mac-cam.jpg" ] && echo yes || echo no)"
} > "$OUT/info.txt"

[ -n "$SERIAL" ] && [ -s "$OUT/selfie.jpg" ] && adb -s "$SERIAL" shell input keyevent KEYCODE_SLEEP 2>/dev/null

# Telegram alert: phone photo (with info) + Mac photo. If the Wi-Fi blocks Telegram,
# they go to the queue and are resent automatically.
MAPS=""; [ -n "$LAT" ] && MAPS="https://maps.google.com/?q=$LAT,$LON"
CAP="🚨 Someone is at the MacBook
$(date '+%F %T')
Mac: $(scutil --get ComputerName) / $(whoami)
Location: ${LAT:-?}, ${LON:-?} (±${ACC:-?} m${LOC_AGE})
$MAPS"
TG_STATUS="Telegram sent"
if [ -s "$OUT/selfie.jpg" ]; then
  tg_send_or_queue "$OUT/selfie.jpg" "$CAP" || TG_STATUS="Telegram waiting for network"
  MAC_CAP="📷 Mac webcam"
else
  MAC_CAP="$CAP"   # no phone photo -> attach the info to the Mac photo
fi
if [ -s "$OUT/mac-cam.jpg" ]; then
  tg_send_or_queue "$OUT/mac-cam.jpg" "$MAC_CAP" || TG_STATUS="Telegram waiting for network"
fi
log "$TG_STATUS"

log "snap saved: $OUT"
# No macOS notification: the intruder would see it on the lock screen, and it wakes
# the display (then the "display off" cancel no longer applies). Telegram reports instead.

# recommended: only NOW shut down, after everything is saved/sent
[ "$ENABLE_SHUTDOWN" = 1 ] && [ "$SHUTDOWN_WHEN" = after_capture ] && do_shutdown
