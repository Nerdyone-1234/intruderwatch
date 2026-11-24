# IntruderWatch – eigene Einstellungen.
# install.sh kopiert diese Datei nach ~/Library/IntruderWatch/config.sh (nur wenn dort
# noch keine liegt). Dort anpassen, NICHT hier: config.sh gehoert nicht ins Repo.
# Schreibweise ": "${NAME:=wert}"" = Standardwert; eine Umgebungsvariable gewinnt.

# --- Handy (adb) ---------------------------------------------------------
# WLAN-adb: IP:Port des Handys (einmal per Kabel `adb tcpip 5555`, siehe
# docs/setup-wlan-adb.txt). Leer lassen = nur Kabel (USB).
: "${PHONE_WIFI:=}"
# USB-Seriennummer aus `adb devices`. Leer = erstes per USB verbundenes Geraet.
: "${PHONE_USB:=}"
# Kamera fuer das Selfie (`scrcpy --list-cameras`). Meist 1 = Frontkamera.
: "${PHONE_CAM_ID:=1}"

# --- Telegram ------------------------------------------------------------
# JSON-Datei mit {"token": "<bot-token>", "allowed_chat_id": "<chat-id>"}.
# Liegt ausserhalb des Repos, chmod 600.
: "${TG_CONFIG:=$HOME/Library/IntruderWatch/telegram.json}"
