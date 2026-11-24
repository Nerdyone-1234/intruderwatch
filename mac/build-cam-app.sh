#!/bin/bash
# Builds MacCamSnap.app into ~/Library/IntruderWatch/ and signs it ad hoc.
set -e
DST="$HOME/Library/IntruderWatch/MacCamSnap.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$DST"; mkdir -p "$DST/Contents/MacOS"
cp "$HERE/MacCamSnap/Info.plist" "$DST/Contents/Info.plist"
cp "$HERE/MacCamSnap/MacCamSnap" "$DST/Contents/MacOS/MacCamSnap"
chmod 755 "$DST/Contents/MacOS/MacCamSnap"
codesign --force --sign - --identifier de.intruderwatch.maccamsnap "$DST"
echo "MacCamSnap.app built. Start it once to grant camera access:"
echo "  open \"$DST\" --args \"$HOME/Desktop/cameratest.jpg\""
