#!/bin/bash
# Baut zwei anklickbare Apps auf den Schreibtisch:
#   "IntruderWatch AUS.app" – schaltet alles ab (+ Mitteilung + Telegram)
#   "IntruderWatch AN.app"  – schaltet wieder ein
set -e
DIR="$HOME/Library/IntruderWatch"
DEST="${1:-$HOME/Desktop}"
build(){ # $1 Name  $2 Argument
  local app="$DEST/$1.app"
  rm -rf "$app"
  # try: ein Fehler soll keinen AppleScript-Dialog oeffnen (Mitteilung kommt vom Skript)
  osacompile -o "$app" -e "try" \
    -e "do shell script \"/bin/bash \" & quoted form of \"$DIR/intruderwatch-switch.sh\" & \" $2\"" \
    -e "end try"
  echo "gebaut: $app"
}
build "IntruderWatch AUS" off
build "IntruderWatch AN" on
