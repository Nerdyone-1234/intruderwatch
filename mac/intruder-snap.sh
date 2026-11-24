#!/bin/bash
# Bei Mac-Fehlanmeldung: Foto von Handy-Frontkamera UND Mac-Webcam, Standort/Metadaten,
# Telegram-Alert mit Vorschau, lokale Kopien, danach (optional) Mac herunterfahren.
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
MAC_CAM_APP="$HOME/Library/IntruderWatch/MacCamSnap.app/Contents/MacOS/MacCamSnap"
PHONE_ALBUM=/sdcard/Pictures/IntruderWatch
ENABLE_SHUTDOWN=1            # 1 = Mac nach Foto herunterfahren, 0 = nicht
SHUTDOWN_WHEN=after_capture  # after_capture (empfohlen) | immediate
OUT="$HOME/Pictures/Intruder/$(date +%Y-%m-%d_%H-%M-%S)"
LOG="$HOME/Library/IntruderWatch/watch.log"
TERMUX_ENV="HOME=/data/data/com.termux/files/home PREFIX=/data/data/com.termux/files/usr PATH=/data/data/com.termux/files/usr/bin LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec.so TMPDIR=/data/data/com.termux/files/usr/tmp ANDROID_DATA=/data ANDROID_ROOT=/system"
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
# shellcheck source=telegram-lib.sh
. "$HOME/Library/IntruderWatch/telegram-lib.sh"
# Abbruch-Logik (warten auf Entsperren, dann Popup mit Geheimantwort): siehe abort-lib.sh
# shellcheck source=abort-lib.sh
. "$HOME/Library/IntruderWatch/abort-lib.sh"
# Handy per WLAN-adb (PHONE_WIFI), USB nur als Notfall: siehe phone-lib.sh
# shellcheck source=phone-lib.sh
. "$HOME/Library/IntruderWatch/phone-lib.sh"

do_shutdown(){
  local why
  if why=$(wait_for_abort); then
    log "shutdown ABGEBROCHEN ($why)"
    # Mitteilung nur bei entsperrtem Mac: auf dem Sperrbildschirm waere sie fuer den
    # Taeter sichtbar und wuerde das Display wecken.
    [ "$why" != "Deckel zu" ] && [ "$why" != "Display aus" ] && osascript -e "display notification \"Herunterfahren abgebrochen\" with title \"IntruderWatch\"" >/dev/null 2>&1
    return
  fi
  log "shutting down mac (force)"
  # 1) passwortfreies sudo (falls eingerichtet)
  if sudo -n /sbin/shutdown -h now >/dev/null 2>&1; then return; fi
  # 2) Fallback: blockierende Apps hart beenden, dann herunterfahren
  for a in Terminal iTerm2 ghostty; do killall -9 "$a" >/dev/null 2>&1; done
  osascript -e 'tell application "System Events" to shut down' >/dev/null 2>&1
}

mkdir -p "$OUT"

# Mac-Webcam-Foto (sofort, bevor der Taeter weg ist)
MAC_CAM_BUNDLE="$HOME/Library/IntruderWatch/MacCamSnap.app"
if [ -d "$MAC_CAM_BUNDLE" ]; then
  open "$MAC_CAM_BUNDLE" --args "$OUT/mac-cam.jpg" 2>>"$LOG"
  for i in 1 2 3 4 5 6 7 8; do [ -s "$OUT/mac-cam.jpg" ] && break; sleep 0.5; done
elif command -v imagesnap >/dev/null; then
  imagesnap -q -w 1.0 "$OUT/mac-cam.jpg" 2>>"$LOG"
fi
[ -s "$OUT/mac-cam.jpg" ] && log "mac-cam ok" || { rm -f "$OUT/mac-cam.jpg"; log "mac-cam FAILED (Kamerazugriff?)"; }

# optional: sofortiges Herunterfahren (nicht empfohlen - Upload wird abgebrochen)
[ "$ENABLE_SHUTDOWN" = 1 ] && [ "$SHUTDOWN_WHEN" = immediate ] && { do_shutdown; }

adb start-server >/dev/null 2>&1
if ! SERIAL=$(phone_target); then
  log "phone not connected (WLAN $PHONE_WIFI / USB $PHONE_USB) - nur Mac-Foto"
else
  log "phone via $([ "$SERIAL" = "$PHONE_WIFI" ] && echo WLAN || echo USB) ($SERIAL)"
  # Selfie zuerst (der Taeter sitzt jetzt vor dem Mac): scrcpy-Kamera ueber adb, auch bei
  # gesperrtem Handy. Termux:API darf die Kamera unter Android 16 im Hintergrund nicht.
  PHONE_CAM_LOG="$OUT/scrcpy.log" phone_selfie "$SERIAL" "$OUT/selfie.jpg" "$OUT/selfie.mkv" \
    && log "handy-selfie ok (scrcpy)"
  # Termux: WLAN-Info + Standort
  adb -s "$SERIAL" shell "run-as com.termux env $TERMUX_ENV /data/data/com.termux/files/usr/bin/sh /data/data/com.termux/files/home/bin/snap.sh" >/dev/null 2>&1
  adb -s "$SERIAL" exec-out run-as com.termux cat files/home/loc.json  > "$OUT/location.json"
  adb -s "$SERIAL" exec-out run-as com.termux cat files/home/wifi.json > "$OUT/phone-wifi.json"
  # Android 16 gibt Termux:API im Hintergrund oft keinen Standort -> letzten bekannten
  # Standort per dumpsys lesen (braucht keine App-Berechtigung, kommt sofort).
  if ! grep -q '"latitude"' "$OUT/location.json" 2>/dev/null; then
    UPTIME=$(adb -s "$SERIAL" shell cat /proc/uptime 2>/dev/null | cut -d' ' -f1)
    if adb -s "$SERIAL" shell dumpsys location 2>/dev/null \
        | python3 "$HOME/Library/IntruderWatch/last_location.py" "$UPTIME" > "$OUT/location.tmp"; then
      mv "$OUT/location.tmp" "$OUT/location.json"; log "standort: letzter bekannter (dumpsys)"
    else
      rm -f "$OUT/location.tmp"; log "standort: keiner gefunden"
    fi
  fi
  if [ -s "$OUT/selfie.jpg" ]; then
    adb -s "$SERIAL" shell "mkdir -p $PHONE_ALBUM" >/dev/null 2>&1
    STAMP=$(date +%Y-%m-%d_%H-%M-%S)
    adb -s "$SERIAL" push "$OUT/selfie.jpg" "$PHONE_ALBUM/intruder_$STAMP.jpg" >/dev/null 2>&1
    adb -s "$SERIAL" shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://$PHONE_ALBUM/intruder_$STAMP.jpg" >/dev/null 2>&1
  else
    log "handy-selfie FEHLT (siehe $OUT/scrcpy.log)"
  fi
fi

# Standort in EINEM Python-Aufruf lesen (Pfad als Argument, nicht in den Code eingesetzt)
read -r LAT LON ACC AGE < <(python3 - "$OUT/location.json" <<'PY' 2>/dev/null
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
print(*(str(d.get(k, "")) or "-" for k in ("latitude", "longitude", "accuracy", "age_s")))
PY
)
[ "$LAT" = - ] && LAT=""; [ "$LON" = - ] && LON=""; [ "$ACC" = - ] && ACC=""; [ "$AGE" = - ] && AGE=""
LOC_AGE=""; [ -n "$AGE" ] && LOC_AGE=", Stand vor $(( (AGE + 30) / 60 )) min"
{
  echo "mac_time: $(date '+%F %T %z')"; echo "mac_user: $(whoami)"; echo "mac_host: $(scutil --get ComputerName)"
  echo "location: $LAT, $LON  (+/- ${ACC} m${LOC_AGE})"
  echo "mac_cam: $([ -f "$OUT/mac-cam.jpg" ] && echo ja || echo nein)"
} > "$OUT/info.txt"

[ -n "$SERIAL" ] && [ -s "$OUT/selfie.jpg" ] && adb -s "$SERIAL" shell input keyevent KEYCODE_SLEEP 2>/dev/null

# Telegram-Alert: Handy-Foto (mit Infos) + Mac-Foto. Blockiert das WLAN Telegram,
# landen sie in der Warteschlange und werden automatisch nachgesendet.
MAPS=""; [ -n "$LAT" ] && MAPS="https://maps.google.com/?q=$LAT,$LON"
CAP="🚨 Jemand am MacBook
$(date '+%F %T')
Mac: $(scutil --get ComputerName) / $(whoami)
Standort: ${LAT:-?}, ${LON:-?} (±${ACC:-?} m${LOC_AGE})
$MAPS"
TG_STATUS="Telegram gesendet"
if [ -s "$OUT/selfie.jpg" ]; then
  tg_send_or_queue "$OUT/selfie.jpg" "$CAP" || TG_STATUS="Telegram wartet auf Netz"
  MAC_CAP="📷 Mac-Webcam"
else
  MAC_CAP="$CAP"   # kein Handy-Foto -> Infos ans Mac-Foto haengen
fi
if [ -s "$OUT/mac-cam.jpg" ]; then
  tg_send_or_queue "$OUT/mac-cam.jpg" "$MAC_CAP" || TG_STATUS="Telegram wartet auf Netz"
fi
log "$TG_STATUS"

log "snap saved: $OUT"
# Keine macOS-Mitteilung: auf dem Sperrbildschirm saehe der Taeter sie, und sie weckt
# das Display (dann greift der Abbruch "Display aus" nicht). Meldung kommt per Telegram.

# empfohlen: erst JETZT herunterfahren, nachdem alles gesichert/gesendet ist
[ "$ENABLE_SHUTDOWN" = 1 ] && [ "$SHUTDOWN_WHEN" = after_capture ] && do_shutdown
