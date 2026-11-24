#!/bin/bash
# Tests fuer mac/telegram-lib.sh – ausfuehren: bash tests/test-telegram-lib.sh
# Telegram wird NICHT wirklich angesprochen: tg_post wird durch eine Attrappe ersetzt.
cd "$(dirname "$0")/.." || exit 1
export IW_CONFIG=/dev/null   # eigene config.sh nicht in Tests laden
. mac/telegram-lib.sh
fail=0; pass=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (erwartet '$2', bekam '$3')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export TG_QUEUE="$TMP/queue"
CFG="$TMP/config.json"; echo '{"token":"T","allowed_chat_id":"42"}' > "$CFG"; export TG_CONFIG="$CFG"
mkjpg(){ printf '\xff\xd8\xff\xe0jpg' > "$1"; }   # minimale JPEG-Signatur
PHOTO="$TMP/foto.jpg"; mkjpg "$PHOTO"
SENT="$TMP/sent.txt"; : > "$SENT"
NET=down
tg_post(){ # $1 token $2 chat $3 photo $4 caption -> gibt Telegram-JSON aus
  [ "$NET" = up ] || return 7
  echo "$3|$4" >> "$SENT"; echo '{"ok":true,"result":{}}'
}
count(){ find "$TG_QUEUE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }

# 1) Netz blockiert -> landet in der Warteschlange
tg_send_or_queue "$PHOTO" "Alarm 1"; check "blockiert -> Rueckgabe 1" 1 $?
check "blockiert -> 1 Eintrag in Queue" 1 "$(count)"
check "blockiert -> nichts gesendet" 0 "$(wc -l < "$SENT" | tr -d ' ')"
check "Queue enthaelt nur Foto + Caption (kein Token)" "caption.txt photo.jpg" "$(ls "$TG_QUEUE"/*/ | sort | xargs)"

# 2) Foto liegt als Kopie in der Queue (ueberlebt Loeschen des Originals)
rm -f "$PHOTO"; check "Foto-Kopie in Queue" 1 "$(ls "$TG_QUEUE"/*/photo.jpg 2>/dev/null | wc -l | tr -d ' ')"

# 3) Flush bei weiter blockiertem Netz -> bleibt drin
tg_flush_queue; check "Flush ohne Netz -> bleibt" 1 "$(count)"

# 4) Netz wieder da -> Flush sendet und leert
NET=up; tg_flush_queue
check "Flush mit Netz -> Queue leer" 0 "$(count)"
check "Flush -> genau 1 gesendet" 1 "$(grep -c "photo.jpg|" "$SENT")"
grep -q "Verspaetet" "$SENT"; check "Caption als verspaetet markiert" 0 $?
grep -q "Alarm 1" "$SENT"; check "Original-Caption erhalten" 0 $?

# 5) Netz da -> direkt gesendet, keine Queue
: > "$SENT"; mkjpg "$PHOTO"
tg_send_or_queue "$PHOTO" "Alarm 2"; check "online -> Rueckgabe 0" 0 $?
check "online -> Queue leer" 0 "$(count)"

# 6) Telegram lehnt dauerhaft ab (400) -> NICHT in Queue (wuerde sie sonst verstopfen)
tg_post(){ echo '{"ok":false,"error_code":400,"description":"Bad Request"}'; }
tg_send_or_queue "$PHOTO" "Alarm 3"; check "400 -> Rueckgabe 2" 2 $?
check "400 -> nicht in Queue" 0 "$(count)"
# 6b) Telegram ueberlastet (429) -> vorruebergehend -> in Queue
tg_post(){ echo '{"ok":false,"error_code":429,"description":"Too Many Requests"}'; }
tg_send_or_queue "$PHOTO" "Alarm 3b"; check "429 -> in Queue" 1 "$(count)"

# 7) Fehlende Config -> trotzdem in Queue (wird spaeter gesendet)
rm -rf "$TG_QUEUE"; export TG_CONFIG="$TMP/fehlt.json"
tg_send_or_queue "$PHOTO" "Alarm 4"; check "ohne Config -> in Queue" 1 "$(count)"

# 8) Textnachricht (z. B. "deaktiviert"): blockiert -> Queue, spaeter gesendet
rm -rf "$TG_QUEUE"; export TG_CONFIG="$CFG"; : > "$SENT"; NET=down
tg_post_text(){ [ "$NET" = up ] || return 7; echo "TEXT|$3" >> "$SENT"; echo '{"ok":true}'; }
tg_post(){ [ "$NET" = up ] || return 7; echo "$3|$4" >> "$SENT"; echo '{"ok":true}'; }
tg_text_or_queue "Aus"; check "Text blockiert -> Rueckgabe 1" 1 $?
check "Text blockiert -> 1 Eintrag" 1 "$(count)"
check "Text-Eintrag ohne Foto" "caption.txt" "$(ls "$TG_QUEUE"/*/ | xargs)"
NET=up; tg_flush_queue
check "Text nachgesendet -> Queue leer" 0 "$(count)"
grep -q "^TEXT|" "$SENT" && grep -q "^Aus" "$SENT"; check "als Text (nicht Foto) gesendet" 0 $?
tg_text_or_queue "An"; check "Text online -> Rueckgabe 0" 0 $?

# 9) (Fund 2) Kaputter Eintrag blockiert die Queue nicht mehr
rm -rf "$TG_QUEUE"; : > "$SENT"; NET=down
tg_post(){ [ "$NET" = up ] || return 7
  case "$4" in *KAPUTT*) echo '{"ok":false,"error_code":400}';; *) echo "$3|$4" >> "$SENT"; echo '{"ok":true}';; esac; }
tg_send_or_queue "$PHOTO" "KAPUTT"; tg_send_or_queue "$PHOTO" "Alarm gut"
check "2 Eintraege wartend" 2 "$(count)"
NET=up; tg_flush_queue
check "Queue danach leer" 0 "$(count)"
grep -q "Alarm gut" "$SENT"; check "guter Eintrag trotzdem gesendet" 0 $?
check "kaputter Eintrag nach .failed verschoben" 1 "$(ls "$TG_QUEUE/.failed" | wc -l | tr -d ' ')"

# 10) (Fund 2) Kein JPEG -> wird nicht gesendet und nicht eingereiht
echo "cat: No such file" > "$TMP/fake.jpg"; : > "$SENT"
tg_send_or_queue "$TMP/fake.jpg" "x"; check "kein JPEG -> Rueckgabe 2" 2 $?
check "kein JPEG -> nicht gesendet" 0 "$(wc -l < "$SENT" | tr -d ' ')"
check "kein JPEG -> nicht in Queue" 0 "$(count)"

# 11) (Fund 3) Halb geschriebener Eintrag (.tmp-*) wird vom Flush nicht angefasst
mkdir -p "$TG_QUEUE/.tmp-halb"; tg_flush_queue
check "halber Eintrag bleibt" 1 "$( [ -d "$TG_QUEUE/.tmp-halb" ] && echo 1 || echo 0)"
rm -rf "$TG_QUEUE/.tmp-halb"
# 11b) Eintraege entstehen nur fertig (kein .tmp-Rest nach Enqueue)
NET=down; tg_send_or_queue "$PHOTO" "Alarm 5"
check "kein .tmp-Rest" 0 "$(find "$TG_QUEUE" -maxdepth 1 -name '.tmp-*' | wc -l | tr -d ' ')"
check "fertiger Eintrag hat Foto" 1 "$(ls "$TG_QUEUE"/2*/photo.jpg 2>/dev/null | wc -l | tr -d ' ')"

# 12) (Fund 6) Alte, verwaiste Sperre wird ueberwunden, frische respektiert
NET=up; mkdir -p "$TG_QUEUE/.lock"; tg_flush_queue
check "frische Sperre -> nicht gesendet" 1 "$(count)"
touch -t 202001010000 "$TG_QUEUE/.lock"; tg_flush_queue
check "alte Sperre -> trotzdem gesendet" 0 "$(count)"
check "Sperre danach freigegeben" 0 "$( [ -d "$TG_QUEUE/.lock" ] && echo 1 || echo 0)"

echo "$pass ok, $fail fehlgeschlagen"; [ $fail -eq 0 ]
