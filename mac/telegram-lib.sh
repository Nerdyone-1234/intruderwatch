#!/bin/bash
# Telegram-Versand mit Warteschlange: Klappt sendPhoto/sendMessage nur
# VORUEBERGEHEND nicht (WLAN blockiert Telegram, offline, 429/5xx), wird der
# Eintrag in TG_QUEUE abgelegt und spaeter von tg_flush_queue gesendet
# (intruder-watch.sh ruft das regelmaessig auf). DAUERHAFTE Ablehnungen (4xx,
# kein JPEG) werden nicht eingereiht bzw. nach TG_QUEUE/.failed verschoben,
# damit sie die Warteschlange nicht verstopfen.
# Token/Chat werden NIE in der Queue gespeichert, sondern beim Senden frisch gelesen.
#
# Rueckgabewerte der Sende-Funktionen: 0 = gesendet, 1 = voruebergehend, 2 = dauerhaft.

IW_CONFIG="${IW_CONFIG:-$HOME/Library/IntruderWatch/config.sh}"
# shellcheck source=config.example.sh
[ -f "$IW_CONFIG" ] && . "$IW_CONFIG"
# JSON {"token": ..., "allowed_chat_id": ...}; Pfad in config.sh einstellbar.
TG_CONFIG="${TG_CONFIG:-$HOME/Library/IntruderWatch/telegram.json}"
TG_QUEUE="${TG_QUEUE:-$HOME/Library/IntruderWatch/queue}"
TG_TIMEOUT="${TG_TIMEOUT:-30}"
TG_MAX_AGE_DAYS="${TG_MAX_AGE_DAYS:-30}"   # aeltere Eintraege verwerfen
TG_LOCK_STALE="${TG_LOCK_STALE:-300}"      # Sperre aelter als das (s) gilt als verwaist
TG_DELAY_TAG="⏳ Verspaetet gesendet (WLAN/Netz war blockiert)"

tg_log(){ declare -F log >/dev/null && log "$*"; return 0; }

# Liest token und chat aus der Config. Ausgabe: "token chat" oder nichts.
tg_credentials(){
  [ -f "$TG_CONFIG" ] || return 1
  /usr/bin/python3 - "$TG_CONFIG" <<'PY' 2>/dev/null
import json, sys
c = json.load(open(sys.argv[1]))
t, ch = c.get("token", ""), str(c.get("allowed_chat_id", ""))
if t and ch: print(t, ch)
PY
}

# HTTP-Aufrufe an Telegram (in Tests ersetzbar).
tg_post(){ # $1 token $2 chat $3 foto $4 text
  curl -s -m "$TG_TIMEOUT" -F "chat_id=$2" -F "photo=@$3" --form-string "caption=$4" \
    "https://api.telegram.org/bot$1/sendPhoto"
}
tg_post_text(){ # $1 token $2 chat $3 text
  curl -s -m "$TG_TIMEOUT" --form-string "chat_id=$2" --form-string "text=$3" \
    "https://api.telegram.org/bot$1/sendMessage"
}

# Ist die Datei ein JPEG (Signatur FF D8 FF)? Schuetzt vor Fehlermeldungen als "Foto".
tg_is_jpeg(){ [ -s "$1" ] && [ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" = ffd8ff ]; }

# Telegram-Antwort bewerten -> 0 ok, 2 dauerhaft (4xx ausser 429), sonst 1.
tg_classify(){
  case "$1" in
    *'"ok":true'*) return 0;;
    *'"error_code":429'*) return 1;;
    *'"error_code":4'[0-9][0-9]*) return 2;;
    *) return 1;;
  esac
}

tg_send_text(){ # $1 text
  local creds resp
  creds=$(tg_credentials) || return 1
  [ -n "$creds" ] || return 1
  # shellcheck disable=SC2086
  set -- $creds "$1"
  resp=$(tg_post_text "$1" "$2" "$3" 2>/dev/null) || return 1
  tg_classify "$resp"
}

tg_send_photo(){ # $1 foto $2 text
  local photo=$1 caption=$2 creds resp
  tg_is_jpeg "$photo" || return 2
  creds=$(tg_credentials) || return 1
  [ -n "$creds" ] || return 1
  # shellcheck disable=SC2086
  set -- $creds
  resp=$(tg_post "$1" "$2" "$photo" "$caption" 2>/dev/null) || return 1
  tg_classify "$resp"
}

# Legt einen Eintrag ATOMAR an: erst in .tmp-* fertig schreiben, dann umbenennen.
# So sieht tg_flush_queue nie einen halb geschriebenen Eintrag. $1 text  $2 foto (optional)
tg_enqueue(){
  local caption=$1 photo=$2 tmp
  mkdir -p "$TG_QUEUE" && chmod 700 "$TG_QUEUE" || return 1
  tmp=$(mktemp -d "$TG_QUEUE/.tmp-XXXXXX") || return 1
  if [ -n "$photo" ] && ! cp "$photo" "$tmp/photo.jpg"; then rm -rf "$tmp"; return 1; fi
  printf "%s" "$caption" > "$tmp/caption.txt" &&
    mv "$tmp" "$TG_QUEUE/$(date +%Y%m%d-%H%M%S)-$$-$RANDOM" || { rm -rf "$tmp"; return 1; }
}

# Foto senden; voruebergehender Fehler -> Queue. Exit 0 gesendet, 1 in Queue, 2 abgelehnt.
tg_send_or_queue(){
  tg_send_photo "$1" "$2"; local rc=$?
  case $rc in
    0) return 0;;
    2) tg_log "telegram: Foto dauerhaft abgelehnt (kein JPEG/4xx) – nicht eingereiht: $1"; return 2;;
  esac
  tg_enqueue "$2" "$1" && tg_log "telegram blockiert/fehlgeschlagen -> in Warteschlange"
  return 1
}

# Text senden; voruebergehender Fehler -> Queue. Exit wie tg_send_or_queue.
tg_text_or_queue(){
  tg_send_text "$1"; local rc=$?
  case $rc in
    0) return 0;;
    2) tg_log "telegram: Text dauerhaft abgelehnt (4xx)"; return 2;;
  esac
  tg_enqueue "$1" && tg_log "telegram-text -> in Warteschlange"
  return 1
}

# Sperre holen; eine verwaiste (aelter als TG_LOCK_STALE) wird uebernommen.
tg_lock(){
  local lock="$TG_QUEUE/.lock" age
  mkdir "$lock" 2>/dev/null && return 0
  age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || date +%s) ))
  [ "$age" -gt "$TG_LOCK_STALE" ] || return 1
  tg_log "warteschlange: verwaiste Sperre ($age s) entfernt"
  rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null
}

# Sendet alle fertigen Eintraege (aelteste zuerst). Voruebergehender Fehler ->
# abbrechen (Netz weg, sonst laeuft jeder Eintrag in den Timeout). Dauerhafter
# Fehler -> nach .failed verschieben und weitermachen.
tg_flush_queue(){
  local entry text rc sent=0
  [ -d "$TG_QUEUE" ] || return 0
  tg_lock || return 0
  find "$TG_QUEUE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -mtime +"$TG_MAX_AGE_DAYS" -exec rm -rf {} + 2>/dev/null
  for entry in $(find "$TG_QUEUE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort); do
    text="$TG_DELAY_TAG
$(cat "$entry/caption.txt" 2>/dev/null)"
    if [ -e "$entry/photo.jpg" ]; then
      tg_send_photo "$entry/photo.jpg" "$text"; rc=$?
    elif [ -s "$entry/caption.txt" ]; then
      tg_send_text "$text"; rc=$?
    else
      rc=2
    fi
    case $rc in
      0) rm -rf "$entry"; sent=$((sent+1));;
      2) mkdir -p "$TG_QUEUE/.failed" && mv "$entry" "$TG_QUEUE/.failed/"
         tg_log "warteschlange: Eintrag dauerhaft abgelehnt -> .failed/$(basename "$entry")";;
      *) break;;
    esac
  done
  rmdir "$TG_QUEUE/.lock" 2>/dev/null
  [ $sent -gt 0 ] && tg_log "warteschlange: $sent Eintrag(e) nachtraeglich gesendet"
  return 0
}
