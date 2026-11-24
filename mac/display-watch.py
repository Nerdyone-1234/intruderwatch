"""Beobachtet, ob das Display an oder aus ist (fuer intruder-watch.sh).

Laeuft dauerhaft als Kind des Waechters und prueft jede Sekunde. Schreibt:
  <dir>/.display_state   "awake" oder "asleep"
  <dir>/.lid_closed_at   Zeitpunkt jedes Display-Wechsels (gemeinsame Markierung
                         mit Deckel-Bewegungen -> Schonfrist LID_GRACE)
Grund: Beim Sperren / Display-Aus schreibt macOS selbst Fehlschlaege, auch bei
offenem Deckel (Vorfall 2026-11-23 16:26). Bei Display aus kann niemand tippen.
Beendet sich, wenn der Waechter (Elternprozess) weg ist.
"""
import os
import sys
import time

import Quartz

CHECK_EVERY = 1  # Sekunden


def display_state():
    return "asleep" if Quartz.CGDisplayIsAsleep(Quartz.CGMainDisplayID()) else "awake"


def write_atomic(path, text):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def main(state_dir):
    state_file = os.path.join(state_dir, ".display_state")
    mark_file = os.path.join(state_dir, ".lid_closed_at")
    parent = os.getppid()
    prev = None
    while os.getppid() == parent:
        state = display_state()
        if state != prev:
            write_atomic(state_file, state)
            if prev is not None:
                write_atomic(mark_file, str(int(time.time())))
            prev = state
        time.sleep(CHECK_EVERY)


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit("Benutzung: display-watch.py <IntruderWatch-Verzeichnis>")
    main(sys.argv[1])
