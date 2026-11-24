# IntruderWatch

Anti-theft tripwire for your own Mac and your own Android phone.

When someone enters the wrong password on the MacBook lock screen several times in
a row, IntruderWatch takes a photo with the Mac webcam and – via adb over a USB
cable or Wi-Fi – with the phone's front camera, reads the phone's location, sends
everything to Telegram and then shuts the Mac down (you can cancel with your
password + a secret answer).

> **For your own devices only.** See [Legal](#legal) below.

> The scripts, log messages and Telegram texts are in German.

## Components

- `mac/intruder-watch.sh` – watches the macOS log for failed logins
  (threshold: 2 failed attempts within 120 s, then 5 min cooldown).
- `mac/intruder-snap.sh` – takes the photos, fetches data from the phone, locks it.
- `mac/phone-lib.sh` – phone connection (Wi-Fi adb first, USB as fallback) and selfie.
- `mac/de.intruderwatch.plist.template` – launchd agent (starts at login).
- `mac/last_location.py` – last known phone location from `dumpsys location`.
- `mac/config.example.sh` – template for your own settings.
- `phone/snap.sh` – runs in Termux on the phone: Wi-Fi info + location.

## Requirements

- Mac (Apple Silicon, Homebrew in `/opt/homebrew`) with
  `brew install imagesnap scrcpy ffmpeg` and `brew install --cask android-platform-tools` (adb).
- Android phone with USB debugging enabled (the scrcpy selfie needs Android 12+;
  tested with a Samsung Galaxy on Android 16). Connected by USB cable **or** Wi-Fi
  (see "Phone: cable or Wi-Fi" below).
- Termux + Termux:API on the phone, `pkg install termux-api`.
- Termux:API permission: location (the Mac takes the selfie via scrcpy).
- `phone/snap.sh` goes to `~/bin/snap.sh` on the phone (Termux home), plus
  `allow-external-apps=true` in `~/.termux/termux.properties`.

## Install (Mac)

```bash
./install.sh
```

Copies the scripts to `~/Library/IntruderWatch/`, fills your home path into the
plist and loads the launchd agent.

## Configuration

Your own settings live in `~/Library/IntruderWatch/config.sh` (`install.sh`
creates it from `mac/config.example.sh`; it never goes into the repo):

- `PHONE_WIFI` – phone IP:port for Wi-Fi adb. Empty = USB cable only.
- `PHONE_USB` – USB serial (`adb devices`). Empty = first USB device.
- `PHONE_CAM_ID` – camera for the selfie (`scrcpy --list-cameras`, usually 1 = front).
- `TG_CONFIG` – path to the Telegram JSON file.

Threshold/window/cooldown are at the top of `mac/intruder-watch.sh`.

## Telegram alert

Create a bot with [@BotFather](https://t.me/BotFather), then create
`~/Library/IntruderWatch/telegram.json` (or the path in `TG_CONFIG`) containing
`{"token": "<bot-token>", "allowed_chat_id": "<your-chat-id>"}` and
`chmod 600` it. Every incident sends a `sendPhoto` with preview, time, Mac name
and a location link. **Never put the token in the repo.**

### Queue when Telegram is blocked

If the network blocks Telegram (school/company network, hotspot without data,
offline) or Telegram does not answer `"ok":true`, the photo and caption are stored
in `~/Library/IntruderWatch/queue/` (a copy of the photo, **no token**). Entries
are written atomically (`.tmp-*` first, then renamed). Only temporary errors
(offline, blocked, 429/5xx) are retried; a permanent rejection (4xx, file is not a
JPEG) goes to `queue/.failed/` and does not block the other photos. A stale lock
(> 5 min) is taken over. The watcher retries every `FLUSH_EVERY` (60) s and right
after login/restart – as soon as Telegram is reachable, the photos arrive marked
"⏳ Verspätet gesendet" (sent late). Entries older than 30 days are dropped.
Logic in `mac/telegram-lib.sh`, tests: `bash tests/test-telegram-lib.sh`.

## Local copy on the phone

Each phone photo is also copied to `/sdcard/Pictures/IntruderWatch/` on the phone
and a media scan is triggered, so it shows up in the gallery.

## Mac webcam photo

Besides the phone, the Mac takes a webcam photo (via `MacCamSnap.app`, see below).
macOS protects the camera with TCC, so the process needs **camera access** once
(System Settings → Privacy & Security → Camera). Without it the Mac photo is
skipped and logged; phone photo and Telegram still work.

## Shutdown

At the top of `mac/intruder-snap.sh`:

- `ENABLE_SHUTDOWN=1` – shut the Mac down after an incident (`0` = off).
- `SHUTDOWN_WHEN=after_capture` – **recommended**: shut down only after photos and
  Telegram are done (otherwise the upload is cut off). `immediate` shuts down right
  away and usually loses the evidence photo.

**Lid closed → no shutdown.** If the lid is closed at shutdown time, it is skipped
(nobody could answer the secret question). The Mac sleeps locked; photos and
Telegram are already out.

## MacCamSnap.app (camera access for the background service)

macOS only grants camera access to signed apps, not to a launchd bash job. That's
why `imagesnap` sits in a small app bundle `MacCamSnap.app` (sources in
`mac/MacCamSnap/`, built by `mac/build-cam-app.sh`). The service starts it with
`open`. **Once** after building, start the app and allow the camera in the macOS
dialog:

```bash
open ~/Library/IntruderWatch/MacCamSnap.app --args ~/Desktop/cameratest.jpg
```

## Cancelling the shutdown

After photos + Telegram (logic in `mac/abort-lib.sh`, tests: `bash tests/test-abort-lib.sh`):

1. **Mac locked:** IntruderWatch waits up to 60 s for you to unlock it with your
   password. If it stays locked → shutdown.
2. **Mac unlocked:** now a popup appears (no question text, hidden input). Enter the
   answer from `~/Library/IntruderWatch/secret.txt` (case-insensitive). Correct →
   no shutdown. Wrong → the popup comes back. No correct answer within 60 s → shutdown.

The popup only appears after unlocking because macOS shows no windows above the
lock screen. Without `secret.txt`, unlocking is enough.

False-alarm protection: if the **lid is closed** or the **display is off** while
waiting, nobody is at the Mac → no shutdown.

## Forced shutdown

The shutdown is forced even if open terminals/apps would ask: first
`sudo -n /sbin/shutdown` (once set up, see `docs/enable-force-shutdown.txt`),
otherwise Terminal/iTerm/ghostty are killed and then the Mac shuts down.

## Off/on switch (desktop)

`install.sh` puts two apps on the desktop (rebuild: `bash mac/build-switch-apps.sh`):

- **IntruderWatch AUS.app** (off) – turns everything off: watcher stopped, stays off
  after restart/login, a running alarm and its shutdown are cancelled.
- **IntruderWatch AN.app** (on) – turns it back on.

Both report via macOS notification **and Telegram** (with time, Mac and user). If
Telegram is blocked, the message is sent later (up to 24 h, even while the watcher
is off). Script: `mac/intruderwatch-switch.sh off|on|status`.

## Health check (every 30 min)

The launchd job `de.intruderwatch.health` runs `mac/intruder-health.sh` every
30 minutes and after login. It checks the service, background processes (watcher,
log stream, `display-watch.py`), heartbeat, lock detection, Telegram config,
installed files and the Telegram queue.

- Watcher stopped → restarted automatically, Telegram "🔧 … neu gestartet".
- Other problem → Telegram warning (same warning at most every 6 h), all-clear
  "✅ wieder alles ok" once fixed.
- Turned off on purpose (off app) → the check stays silent.

Manual status: `bash ~/Library/IntruderWatch/intruder-health.sh --report`
(logic in `mac/health-lib.sh`, tests: `bash tests/test-health-lib.sh`).

## Phone: cable or Wi-Fi

- **Cable (default):** leave `PHONE_WIFI` empty, plug the phone in via USB, allow
  USB debugging. Done.
- **Wi-Fi:** run `adb tcpip 5555` once over the cable, then set
  `PHONE_WIFI=<IP>:5555` in `config.sh` (guide: `docs/setup-wlan-adb.txt`).
  USB remains the fallback.

- During an alarm: Wi-Fi connected → use it; port open → reconnect; otherwise USB if
  the cable is plugged in; otherwise Mac photo only. The port check times out after 2 s.
- After a phone reboot, Wi-Fi adb is off. The health check (every 30 min) turns it
  back on via `adb tcpip 5555` as soon as the cable is plugged in, and reconnects.
  This never happens during an alarm (it would briefly drop USB).
- Selfie: `scrcpy --video-source=camera --camera-id=1 --force-adb-forward` records
  3 s of video; the last frame becomes `selfie.jpg`, the video is kept as
  `selfie.mkv`. Works with the phone locked and shows nothing on it. Up to 2 attempts
  (the first start after a pause sometimes fails); scrcpy output goes to
  `scrcpy.log` in the alarm folder. Termux:API may not use the camera in the
  background on Android 16. Camera ID in `PHONE_CAM_ID`. Depending on how the phone
  is lying, the picture may be upside down.
- Location: if Termux can't get one, the Mac reads the last known location via
  `adb shell dumpsys location` (`mac/last_location.py`).
- With Wi-Fi the phone needs a fixed IP in the router (DHCP reservation), otherwise
  `PHONE_WIFI` will eventually be wrong.
- Status: `bash ~/Library/IntruderWatch/intruder-health.sh --report` shows
  "Handy: erreichbar (…)" (phone reachable). Tests: `bash tests/test-phone-lib.sh`.

## Trigger logic (avoiding false alarms)

The watcher counts a failed attempt **only** if all of these hold:
1. **The screen is locked** (`is_locked.py` via PyObjC). So `sudo` typos or app
   password prompts on an unlocked Mac do **not** trigger.
2. **The Mac has not just woken up** (heartbeat file; `WAKE_GRACE` s). On wake,
   macOS flushes buffered auth failures.
3. **The lid is open and was opened more than `LID_GRACE` (2) s ago, or the Mac woke
   more than 2 s ago.** macOS writes its own failures only with the lid closed –
   those are ignored. On closing the lid macOS itself logs 2–3 auth failures –
   this used to trigger photo + shutdown on every lid close.
4. **The display is on.** On locking / display off, macOS writes its own failures
   even with the lid open. Nobody can type with the display off.
   `mac/display-watch.py` (a child of the watcher) checks this every second; a
   display change also starts the `LID_GRACE` grace period.
5. **No duplicate entry:** entries less than `BURST` (2) s apart – measured by the
   time **in the log**, not processing time – count as one attempt.

If `is_locked.py` returns nothing (e.g. pyobjc missing after a Python update), the
watcher logs an error and sends a Telegram warning at most hourly – instead of
silently never triggering again.

The logic lives, testable, in `mac/watch-lib.sh`; tests: `bash tests/test-watch-lib.sh`.

It only triggers after `THRESH` real lock-screen failures within `WINDOW` seconds,
then stays quiet for `COOLDOWN` seconds. Values at the top of `mac/intruder-watch.sh`.

**After a restart:** the service starts automatically once you log in
(`RunAtLoad`/`KeepAlive`). It does not run at the login window before the first
login – a macOS limit for per-user services.

## Tests

```bash
for t in tests/test-*.sh; do bash "$t"; done
```

The tests replace adb, Telegram, the clock and popups with fakes – no phone, no
network and no credentials needed.

## Legal

IntruderWatch is theft protection for **your own** devices. It photographs the
person entering wrong passwords on the Mac and records location data.

- Only use it on devices you own.
- Anyone else who uses the Mac (family, flatmates, colleagues) must know about it.
  Covert recordings of other people may be illegal depending on your country
  (in Germany e.g. the right to one's own image, § 201a StGB, GDPR).
- Use the photos only to investigate a theft (e.g. for the police); do not publish them.
- No warranty: the software comes without any guarantee, use at your own risk
  (see LICENSE).
