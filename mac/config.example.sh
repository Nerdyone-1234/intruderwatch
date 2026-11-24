# IntruderWatch – your own settings.
# install.sh copies this file to ~/Library/IntruderWatch/config.sh (only if there is
# none yet). Edit it THERE, not here: config.sh never goes into the repo.
# Notation ": "${NAME:=value}"" = default value; an environment variable wins.

# --- Phone (adb) ---------------------------------------------------------
# Wi-Fi adb: the phone's IP:port (run `adb tcpip 5555` once over the cable, see
# docs/setup-wifi-adb.txt). Leave empty = cable only (USB).
: "${PHONE_WIFI:=}"
# USB serial from `adb devices`. Empty = first device connected via USB.
: "${PHONE_USB:=}"
# Camera for the selfie (`scrcpy --list-cameras`). Usually 1 = front camera.
: "${PHONE_CAM_ID:=1}"

# --- Telegram ------------------------------------------------------------
# JSON file with {"token": "<bot-token>", "allowed_chat_id": "<chat-id>"}.
# Lives outside the repo, chmod 600.
: "${TG_CONFIG:=$HOME/Library/IntruderWatch/telegram.json}"
