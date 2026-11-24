#!/bin/bash
# Builds two clickable apps on the desktop:
#   "IntruderWatch OFF.app" – turns everything off (+ notification + Telegram)
#   "IntruderWatch ON.app"  – turns it back on
set -e
DIR="$HOME/Library/IntruderWatch"
DEST="${1:-$HOME/Desktop}"
build(){ # $1 name  $2 argument
  local app="$DEST/$1.app"
  rm -rf "$app"
  # try: an error must not open an AppleScript dialog (the script sends a notification)
  osacompile -o "$app" -e "try" \
    -e "do shell script \"/bin/bash \" & quoted form of \"$DIR/intruderwatch-switch.sh\" & \" $2\"" \
    -e "end try"
  echo "built: $app"
}
build "IntruderWatch OFF" off
build "IntruderWatch ON" on
