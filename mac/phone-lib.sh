#!/bin/bash
# Handy-Verbindung per adb (von intruder-snap.sh und intruder-health.sh benutzt).
#
# Einstellungen in ~/Library/IntruderWatch/config.sh (Vorlage mac/config.example.sh):
#   PHONE_WIFI = IP:Port fuer WLAN-adb (per `adb tcpip 5555`). Leer = nur Kabel (USB).
#   PHONE_USB  = USB-Seriennummer. Leer = erstes per USB verbundenes Geraet.
# Mit PHONE_WIFI wird zuerst WLAN versucht, USB ist dann Notfall.
#
#   phone_target         -> gibt das adb-Ziel aus (WLAN zuerst, sonst USB).
#                           Exit 0 = Handy erreichbar, 1 = nicht erreichbar.
#                           Im Alarm wird NIE `adb tcpip` ausgefuehrt (startet adbd
#                           neu und wuerde die USB-Verbindung kurz kappen).
#   phone_keep_wireless  -> fuer den Gesundheits-Check: haelt WLAN-adb am Leben.
#                           Nach einem Handy-Neustart ist der WLAN-Modus aus; steckt
#                           dann das Kabel, wird er per USB wieder eingeschaltet.
#                           Ausgabe: ok | verbunden | per USB eingeschaltet | nicht erreichbar
#   phone_selfie Z F V   -> Foto der Frontkamera per scrcpy (Video V, letztes Bild -> F).
#
# Die ph_*-Funktionen sind in Tests ersetzbar.

IW_CONFIG="${IW_CONFIG:-$HOME/Library/IntruderWatch/config.sh}"
# shellcheck source=config.example.sh
[ -f "$IW_CONFIG" ] && . "$IW_CONFIG"
PHONE_WIFI="${PHONE_WIFI:-}"
PHONE_USB="${PHONE_USB:-}"
PHONE_PORT="${PHONE_PORT:-5555}"
PH_WAIT_TRIES="${PH_WAIT_TRIES:-6}"   # x 0,5 s auf "device" nach dem Verbinden warten
# Selfie per scrcpy (Kamera ueber adb, ohne Termux:API – Android 16 blockiert dort die
# Kamera im Hintergrund). Funktioniert auch bei gesperrtem Handy, zeigt nichts an.
PHONE_CAM_ID="${PHONE_CAM_ID:-1}"          # `scrcpy --list-cameras`; meist 1 = Frontkamera
PHONE_CAM_SECONDS="${PHONE_CAM_SECONDS:-3}" # Videolaenge; letztes Bild = Foto (Belichtung eingeschwungen)
PHONE_CAM_MAX_WAIT="${PHONE_CAM_MAX_WAIT:-20}" # scrcpy haengt? nach so vielen s abbrechen
# Der erste scrcpy-Start nach einer Pause scheitert manchmal ("Server connection failed")
# -> so viele Versuche. Meldungen von scrcpy landen in PHONE_CAM_LOG (snap: Alarm-Ordner).
PHONE_CAM_TRIES="${PHONE_CAM_TRIES:-2}"
PHONE_CAM_LOG="${PHONE_CAM_LOG:-/dev/null}"

# Zustand laut `adb devices` (device | offline | unauthorized | leer = nicht gelistet).
ph_state(){ adb devices 2>/dev/null | awk -v t="$1" '$1 == t { print $2 }'; }
# Erstes per USB verbundenes Geraet (Seriennummer ohne ":" = kein WLAN-Ziel).
ph_first_usb(){ adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" && $1 !~ /:/ { print $1; exit }'; }
# Port-Check mit 2 s Zeitlimit, damit ein abwesendes Handy den Alarm nicht aufhaelt.
ph_port_open(){ nc -z -G 2 "$1" "$2" >/dev/null 2>&1; }
ph_connect(){ adb connect "$1" >/dev/null 2>&1; }
ph_disconnect(){ adb disconnect "$1" >/dev/null 2>&1; }
ph_tcpip(){ adb -s "$1" tcpip "$2" >/dev/null 2>&1; }
ph_settle(){ sleep 3; }   # nach `adb tcpip` braucht adbd auf dem Handy einen Moment
ph_nap(){ sleep 0.5; }

# Kamera-Video aufnehmen ($1 = adb-Ziel, $2 = Video). Mit Zeitlimit-Waechter,
# damit ein haengendes scrcpy den Alarm nicht blockiert.
ph_scrcpy_record(){
  command -v scrcpy >/dev/null || { echo "scrcpy nicht gefunden" >> "$PHONE_CAM_LOG"; return 1; }
  # --force-adb-forward: Tunnel Mac -> Handy (adb forward) statt adb reverse.
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
# Letztes Bild des Videos als JPEG ($1 = Video, $2 = Foto).
ph_last_frame(){ ffmpeg -loglevel error -y -sseof -0.5 -i "$1" -frames:v 1 -q:v 2 "$2" </dev/null >/dev/null 2>&1; }
ph_is_jpeg(){ [ -s "$1" ] && [ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" = ffd8ff ]; }
ph_cam_pause(){ sleep 1; }   # zwischen zwei scrcpy-Versuchen

# phone_selfie <adb-ziel> <foto.jpg> <video.mkv>: Exit 0 = JPEG da (Video bleibt als Beweis).
# Bis zu PHONE_CAM_TRIES scrcpy-Versuche; ffmpeg nur, wenn ein Video da ist.
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

# WLAN verbinden, falls der Port offen ist. Exit 0 = WLAN-Ziel ist "device".
_ph_wifi_up(){
  [ -n "$PHONE_WIFI" ] || return 1               # Nur-Kabel-Modus
  local st; st=$(ph_state "$PHONE_WIFI")
  [ "$st" = device ] && return 0
  ph_port_open "$(_ph_host)" "$(_ph_port)" || return 1
  [ -n "$st" ] && ph_disconnect "$PHONE_WIFI"   # veralteter Eintrag (offline o. ae.)
  ph_connect "$PHONE_WIFI"
  _ph_wait_device "$PHONE_WIFI"
}

# USB-Seriennummer: PHONE_USB oder (leer) das erste USB-Geraet. Exit 0 = verbunden.
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
  if [ -z "$PHONE_WIFI" ]; then                  # Nur-Kabel-Modus: nichts am Leben zu halten
    if _ph_usb >/dev/null; then echo ok; return 0; fi
    echo "nicht erreichbar"; return 1
  fi
  if [ "$(ph_state "$PHONE_WIFI")" = device ]; then echo ok; return 0; fi
  if _ph_wifi_up; then echo verbunden; return 0; fi
  if usb=$(_ph_usb); then
    ph_tcpip "$usb" "$(_ph_port)"
    ph_settle
    if _ph_wifi_up; then echo "per USB eingeschaltet"; return 0; fi
  fi
  echo "nicht erreichbar"; return 1
}
