#!/data/data/com.termux/files/usr/bin/sh
cd "$HOME"
rm -f snap.jpg loc.json wifi.json snap.done
# Das Selfie macht der Mac per scrcpy (Termux:API darf die Kamera unter Android 16
# im Hintergrund nicht).
termux-wifi-connectioninfo > wifi.json 2>&1
# Android 16 gibt Termux:API im Hintergrund meist keinen Standort. Der Mac liest dann
# den letzten bekannten Standort per `dumpsys location` -> hier nur kurz versuchen,
# damit der Telegram-Alarm nicht ~35 s wartet.
timeout 6 termux-location -p network -r once > loc.json 2>&1
touch snap.done
