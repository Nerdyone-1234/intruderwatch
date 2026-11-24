"""Watches whether the display is on or off (for intruder-watch.sh).

Runs permanently as a child of the watcher and checks every second. Writes:
  <dir>/.display_state   "awake" or "asleep"
  <dir>/.lid_closed_at   time of every display change (shared mark with lid
                         movements -> grace period LID_GRACE)
Reason: on locking / display off, macOS itself writes auth failures, even with the
lid open (incident 2026-11-23 16:26). With the display off nobody can type.
Exits when the watcher (parent process) is gone.
"""
import os
import sys
import time

import Quartz

CHECK_EVERY = 1  # seconds


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
        sys.exit("Usage: display-watch.py <IntruderWatch directory>")
    main(sys.argv[1])
