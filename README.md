# IntruderWatch

Anti-Diebstahl-Stolperdraht für den eigenen Mac + das eigene Android-Handy.

Wenn am Sperrbildschirm des MacBooks mehrmals hintereinander das falsche Passwort
eingegeben wird, macht IntruderWatch ein Foto mit der Mac-Webcam und – über adb per
USB-Kabel oder WLAN – mit der Frontkamera des Handys, holt den Standort des Handys,
schickt alles per Telegram und fährt den Mac danach herunter (abbrechbar mit
Passwort + Geheimantwort).

> **Nur für die eigenen Geräte.** Siehe [Rechtliches](#rechtliches) unten.

## Teile

- `mac/intruder-watch.sh` – lauscht im macOS-Log auf fehlgeschlagene Anmeldungen
  (Schwelle: 2 Fehlversuche in 120 s, danach 5 min Ruhe).
- `mac/intruder-snap.sh` – löst Foto aus, holt Daten vom Handy, sperrt es.
- `mac/phone-lib.sh` – Handy-Verbindung: WLAN-adb zuerst, USB nur als Notfall.
- `mac/de.intruderwatch.plist.template` – launchd-Agent (startet beim Login).
- `mac/last_location.py` – letzter bekannter Handy-Standort aus `dumpsys location`.
- `mac/config.example.sh` – Vorlage für die eigenen Einstellungen.
- `phone/snap.sh` – läuft in Termux auf dem Handy: WLAN-Info + Standort.

## Voraussetzungen

- Mac (Apple Silicon, Homebrew unter `/opt/homebrew`) mit
  `brew install imagesnap scrcpy ffmpeg` und `brew install --cask android-platform-tools` (adb).
- Android-Handy mit aktiviertem USB-Debugging (Selfie per scrcpy braucht
  Android 12+; getestet mit Samsung Galaxy, Android 16). Verbunden per USB-Kabel
  **oder** WLAN (siehe „Handy: Kabel oder WLAN“ unten).
- Termux + Termux:API auf dem Handy, `pkg install termux-api`.
- Berechtigungen für Termux:API: Standort (das Selfie macht der Mac per scrcpy).
- `phone/snap.sh` liegt auf dem Handy unter
  `~/bin/snap.sh` (Termux-Home), dazu `allow-external-apps=true`
  in `~/.termux/termux.properties`.

## Installieren (Mac)

```bash
./install.sh
```

Setzt die Skripte nach `~/Library/IntruderWatch/`, trägt den eigenen Benutzerpfad
in die plist ein und lädt den launchd-Agent.

## Konfiguration

Eigene Einstellungen stehen in `~/Library/IntruderWatch/config.sh` (legt
`install.sh` aus `mac/config.example.sh` an, gehört nicht ins Repo):

- `PHONE_WIFI` – IP:Port des Handys für WLAN-adb. Leer = nur USB-Kabel.
- `PHONE_USB` – USB-Seriennummer (`adb devices`). Leer = erstes USB-Gerät.
- `PHONE_CAM_ID` – Kamera fürs Selfie (`scrcpy --list-cameras`, meist 1 = vorne).
- `TG_CONFIG` – Pfad zur Telegram-JSON-Datei.

Schwelle/Fenster/Ruhezeit oben in `mac/intruder-watch.sh`.

## Telegram-Alert

Bot bei [@BotFather](https://t.me/BotFather) anlegen, dann eine Datei
`~/Library/IntruderWatch/telegram.json` (oder Pfad aus `TG_CONFIG`) mit
`{"token": "<bot-token>", "allowed_chat_id": "<deine-chat-id>"}` anlegen und
`chmod 600` setzen. Bei jedem Vorfall kommt ein `sendPhoto` mit Bildvorschau,
Zeit, Mac-Name und Standort-Link. **Der Token gehört nie ins Repo.**

### Warteschlange, wenn Telegram blockiert ist

Blockiert das WLAN Telegram (Schul-/Firmennetz, Hotspot ohne Daten, offline)
oder antwortet Telegram nicht mit `"ok":true`, wird das Foto samt Text in
`~/Library/IntruderWatch/queue/` abgelegt (Kopie des Fotos, **kein Token**).
Einträge werden atomar angelegt (erst `.tmp-*`, dann umbenannt). Nur
vorübergehende Fehler (offline, blockiert, 429/5xx) werden wiederholt; eine
dauerhafte Ablehnung (4xx, Datei ist kein JPEG) landet in `queue/.failed/` und
blockiert die übrigen Fotos nicht. Eine verwaiste Sperre (> 5 min) wird übernommen.
Der Wächter versucht alle `FLUSH_EVERY` (60) s erneut und direkt nach Login/
Neustart – sobald Telegram erreichbar ist, kommen die Fotos mit dem Hinweis
„⏳ Verspätet gesendet“ an. Einträge älter als 30 Tage werden verworfen.
Logik in `mac/telegram-lib.sh`, Tests: `bash tests/test-telegram-lib.sh`.

## Lokale Kopie auf dem Handy

Jedes Foto wird zusätzlich nach `/sdcard/Pictures/IntruderWatch/` auf dem Handy
kopiert und ein Media-Scan angestoßen, sodass es in der Galerie auftaucht.

## Mac-Webcam-Foto

Zusätzlich zum Handy macht der Mac ein Webcam-Foto (über `MacCamSnap.app`,
siehe unten). macOS schützt die Kamera über TCC, deshalb muss
dem ausführenden Prozess einmal **Kamerazugriff** erteilt werden
(System­einstellungen → Datenschutz & Sicherheit → Kamera). Fehlt die Freigabe,
wird das Mac-Foto übersprungen und im Log vermerkt; Handy-Foto und Telegram
laufen trotzdem.

## Herunterfahren

Oben in `mac/intruder-snap.sh`:

- `ENABLE_SHUTDOWN=1` – Mac nach dem Vorfall herunterfahren (`0` = aus).
- `SHUTDOWN_WHEN=after_capture` – **empfohlen**: erst herunterfahren, wenn
  Fotos + Telegram gesichert sind (sonst wird der Upload abgebrochen).
  `immediate` fährt sofort herunter und verliert i. d. R. das Beweisfoto.

**Deckel zu → kein Herunterfahren.** Ist der Deckel beim Herunterfahren
geschlossen, wird es übersprungen (die Geheimfrage kann dann niemand
beantworten). Der Mac schläft gesperrt; Fotos und Telegram sind schon raus.

## MacCamSnap.app (Kamera-Freigabe im Dauerbetrieb)

macOS gibt die Kamera nur signierten Apps frei, nicht einem launchd-Bash-Job.
Deshalb liegt `imagesnap` in einem kleinen App-Bundle `MacCamSnap.app`
(Quellen unter `mac/MacCamSnap/`, Bau per `mac/build-cam-app.sh`). Der Dienst
startet es per `open`. **Einmalig** nach dem Bauen die App starten und im
macOS-Dialog die Kamera erlauben:

```bash
open ~/Library/IntruderWatch/MacCamSnap.app --args ~/Desktop/kameratest.jpg
```

## Herunterfahren stoppen

Nach Fotos + Telegram (Logik in `mac/abort-lib.sh`, Tests: `bash tests/test-abort-lib.sh`):

1. **Mac gesperrt:** IntruderWatch wartet bis zu 60 s, dass du ihn mit deinem
   Passwort entsperrst. Bleibt er gesperrt → Herunterfahren.
2. **Mac entsperrt:** Jetzt erscheint das Popup (ohne Fragetext, verdeckte
   Eingabe). Gib die Antwort aus `~/Library/IntruderWatch/secret.txt` ein
   (Groß-/Klein egal). Richtig → kein Herunterfahren. Falsch → Popup kommt
   wieder. Keine richtige Antwort binnen 60 s → Herunterfahren.

Das Popup kommt erst nach dem Entsperren, weil macOS keine Fenster über dem
Sperrbildschirm zeigt. Ohne `secret.txt` reicht das Entsperren.

Schutz vor Fehlalarmen: Ist während des Wartens der **Deckel zu** oder das
**Display aus**, sitzt niemand am Mac → kein Herunterfahren.

## Erzwungenes Herunterfahren

Das Herunterfahren wird erzwungen, auch wenn offene Terminals/Apps nachfragen:
zuerst `sudo -n /sbin/shutdown` (sobald einmal eingerichtet, siehe
`docs/enable-force-shutdown.txt`), sonst werden Terminal/iTerm/ghostty hart
beendet und dann heruntergefahren.

## Aus-/Einschalter (Schreibtisch)

`install.sh` legt zwei Apps auf den Schreibtisch (neu bauen: `bash mac/build-switch-apps.sh`):

- **IntruderWatch AUS.app** – schaltet alles ab: Wächter gestoppt, bleibt auch nach
  Neustart/Login aus, ein laufender Alarm samt Herunterfahren wird abgebrochen.
- **IntruderWatch AN.app** – schaltet wieder ein.

Beides meldet sich per macOS-Mitteilung **und Telegram** („🔕 IntruderWatch wurde
AUSGESCHALTET“ mit Zeit, Mac und Benutzer). Ist Telegram blockiert, wird die
Nachricht nachgesendet (bis 24 h, auch wenn der Wächter aus ist).
Skript: `mac/intruderwatch-switch.sh off|on|status`.

## Gesundheits-Check (alle 30 min)

Der launchd-Job `de.intruderwatch.health` startet `mac/intruder-health.sh` alle
30 Minuten und nach dem Login. Er prüft Dienst, Hintergrundprozesse
(Wächter, Log-Überwachung, `display-watch.py`), Heartbeat, Sperr-Erkennung,
Telegram-Config, installierte Dateien und die Telegram-Warteschlange.

- Wächter gestoppt → wird automatisch neu gestartet, Telegram: „🔧 … neu gestartet“.
- Anderes Problem → Telegram-Warnung (gleiche Warnung höchstens alle 6 h),
  Entwarnung „✅ wieder alles ok“, sobald behoben.
- Absichtlich ausgeschaltet (AUS-App) → Check bleibt still.

Status von Hand: `bash ~/Library/IntruderWatch/intruder-health.sh --report`
(Logik in `mac/health-lib.sh`, Tests: `bash tests/test-health-lib.sh`).

## Handy: Kabel oder WLAN

- **Kabel (Standard):** `PHONE_WIFI` leer lassen, Handy per USB anstecken,
  USB-Debugging zulassen. Fertig.
- **WLAN:** einmal per Kabel `adb tcpip 5555`, dann `PHONE_WIFI=<IP>:5555` in
  `config.sh` (Anleitung `docs/setup-wlan-adb.txt`). USB bleibt Notfall.

- Im Alarm: WLAN verbunden → sofort nutzen; Port offen → neu verbinden; sonst USB,
  falls das Kabel steckt; sonst nur Mac-Foto. Der Port-Check hat 2 s Zeitlimit.
- Nach einem Handy-Neustart ist der WLAN-Modus aus. Der Gesundheits-Check (alle
  30 min) schaltet ihn per `adb tcpip 5555` wieder ein, sobald das Kabel steckt,
  und verbindet neu. Im Alarm selbst passiert das nie (würde USB kurz trennen).
- Selfie: `scrcpy --video-source=camera --camera-id=1` nimmt 3 s Video auf, das
  letzte Bild wird `selfie.jpg`, das Video bleibt als `selfie.mkv`. Klappt auch bei
  gesperrtem Handy und zeigt dort nichts an. Termux:API darf die Kamera unter
  Android 16 im Hintergrund nicht. Kamera-ID in `PHONE_CAM_ID`. Je nach Lage des
  Handys kann das Bild auf dem Kopf stehen.
- Standort: kommt Termux nicht dran, liest der Mac den letzten bekannten Standort
  per `adb shell dumpsys location` (`mac/last_location.py`).
- Das Handy braucht im Router eine feste IP (DHCP-Reservierung), sonst passt
  `PHONE_WIFI` irgendwann nicht mehr.
- Status: `bash ~/Library/IntruderWatch/intruder-health.sh --report` zeigt
  „Handy: erreichbar (…)“. Tests: `bash tests/test-phone-lib.sh`.

## Auslöse-Logik (Fehlalarme vermeiden)

Der Wächter zählt einen Fehlversuch **nur**, wenn beide Bedingungen gelten:
1. **Bildschirm ist gesperrt** (`is_locked.py` via PyObjC). So lösen `sudo`-
   Vertipper oder App-Passwort-Abfragen bei entsperrtem Mac **nicht** aus.
2. **Der Mac ist nicht gerade aufgewacht** (Heartbeat-Datei; `WAKE_GRACE` Sek.).
   Beim Aufwachen aus dem Sleep spült macOS gepufferte Auth-Fehlschläge nach.
3. **Der Deckel ist offen und wurde vor mehr als `LID_GRACE` (2) Sek. aufgeklappt
   bzw. der Mac ist vor mehr als 2 Sek. aufgewacht.** macOS schreibt eigene
   Fehlschläge nur bei zugeklapptem Deckel – die werden ignoriert.
   Beim Zuklappen loggt macOS selbst 2–3 Auth-Fehlschläge – früher löste das
   Foto + Herunterfahren bei jedem Zuklappen aus.
4. **Das Display ist an.** Beim Sperren / Display-Aus schreibt macOS eigene
   Fehlschläge, auch bei offenem Deckel. Bei ausgeschaltetem Display kann niemand
   tippen. `mac/display-watch.py` (läuft als Kind des Wächters) prüft das jede
   Sekunde; ein Display-Wechsel startet auch die `LID_GRACE`-Schonfrist.
5. **Kein Doppel-Eintrag:** Einträge mit weniger als `BURST` (2) Sek. Abstand –
   gemessen an der Zeit **im Log**, nicht der Verarbeitung – zählen als ein Versuch.

Liefert `is_locked.py` kein Ergebnis (z. B. pyobjc fehlt nach Python-Update),
schreibt der Wächter einen FEHLER ins Log und schickt höchstens stündlich eine
Telegram-Warnung – statt still nie mehr auszulösen.

Die Logik steckt testbar in `mac/watch-lib.sh`; Tests: `bash tests/test-watch-lib.sh`.

Erst ab `THRESH` echten Sperrbildschirm-Fehlversuchen in `WINDOW` Sekunden wird
ausgelöst, danach `COOLDOWN` Sekunden Ruhe. Werte oben in `mac/intruder-watch.sh`.

**Nach Neustart:** Der Dienst startet automatisch, sobald du dich anmeldest
(`RunAtLoad`/`KeepAlive`). Am reinen Login-Bildschirm vor der ersten Anmeldung
läuft er nicht – das ist eine macOS-Grenze für Benutzerdienste.

## Tests

```bash
for t in tests/test-*.sh; do bash "$t"; done
```

Die Tests ersetzen adb, Telegram, Uhr und Popups durch Attrappen – kein Handy,
kein Netz und keine Zugangsdaten nötig.

## Rechtliches

IntruderWatch ist ein Diebstahlschutz für **eigene** Geräte. Es fotografiert die
Person, die am Mac falsche Passwörter eingibt, und erfasst Standortdaten.

- Nur auf Geräten einsetzen, die dir gehören.
- Wer den Mac sonst noch benutzt (Familie, Mitbewohner, Kollegen), muss davon
  wissen. Heimliche Aufnahmen anderer Personen können je nach Land verboten sein
  (in Deutschland u. a. Recht am eigenen Bild, § 201a StGB, DSGVO).
- Fotos nur zur Aufklärung eines Diebstahls nutzen (z. B. für die Polizei),
  nicht veröffentlichen.
- Keine Gewähr: Software ohne Garantie, Nutzung auf eigenes Risiko (siehe LICENSE).
