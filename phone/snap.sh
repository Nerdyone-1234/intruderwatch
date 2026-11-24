#!/data/data/com.termux/files/usr/bin/sh
cd "$HOME"
rm -f snap.jpg loc.json wifi.json snap.done
# The Mac takes the selfie via scrcpy (Termux:API may not use the camera in the
# background on Android 16).
termux-wifi-connectioninfo > wifi.json 2>&1
# Android 16 usually gives Termux:API no location in the background. The Mac then
# reads the last known location via `dumpsys location` -> only try briefly here,
# so the Telegram alert doesn't wait ~35 s.
timeout 6 termux-location -p network -r once > loc.json 2>&1
touch snap.done
