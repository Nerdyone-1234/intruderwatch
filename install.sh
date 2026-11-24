#!/bin/bash
set -e
DST="$HOME/Library/IntruderWatch"
mkdir -p "$DST" "$HOME/Pictures/Intruder" "$HOME/Library/LaunchAgents"
cp mac/intruder-snap.sh mac/intruder-watch.sh mac/watch-lib.sh mac/telegram-lib.sh mac/abort-lib.sh mac/phone-lib.sh mac/intruderwatch-switch.sh mac/is_locked.py mac/last_location.py mac/display-watch.py mac/health-lib.sh mac/intruder-health.sh "$DST/"
/opt/homebrew/bin/pip3 install --break-system-packages -q pyobjc-framework-Quartz
bash mac/build-cam-app.sh
bash mac/build-switch-apps.sh
chmod 755 "$DST"/*.sh
sed "s#__HOME__#$HOME#g" mac/de.intruderwatch.plist.template > "$HOME/Library/LaunchAgents/de.intruderwatch.plist"
launchctl bootout "gui/$(id -u)/de.intruderwatch" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/de.intruderwatch.plist"
# Health check every 30 min (restarts the watcher if needed, warns via Telegram)
sed "s#__HOME__#$HOME#g" mac/de.intruderwatch.health.plist.template > "$HOME/Library/LaunchAgents/de.intruderwatch.health.plist"
launchctl bootout "gui/$(id -u)/de.intruderwatch.health" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/de.intruderwatch.health.plist"
if [ ! -f "$DST/config.sh" ]; then
  cp mac/config.example.sh "$DST/config.sh"
  echo "Settings created: $DST/config.sh  (edit phone and Telegram file)"
fi
chmod 600 "$DST/config.sh"
if [ ! -f "$DST/secret.txt" ]; then
  read -r -s -p "Secret answer (cancels the shutdown): " ANS; echo
  [ -n "$ANS" ] && printf "%s\n" "$ANS" > "$DST/secret.txt"
fi
[ -f "$DST/secret.txt" ] && chmod 600 "$DST/secret.txt"
echo "IntruderWatch installed and started."
echo "The phone script phone/snap.sh must be placed separately in Termux (~/bin/snap.sh)."
command -v scrcpy >/dev/null && command -v ffmpeg >/dev/null \
  || echo "WARNING: scrcpy/ffmpeg missing -> no phone selfie (brew install scrcpy ffmpeg)"
