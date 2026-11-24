#!/usr/bin/env python3
"""Letzten bekannten Handy-Standort aus `adb shell dumpsys location` lesen.

Aufruf:  adb shell dumpsys location | last_location.py <uptime-sekunden>
  <uptime-sekunden> = erste Zahl aus `adb shell cat /proc/uptime` (fuer das Alter).

Ausgabe: JSON wie Termux-location.json (latitude, longitude, accuracy) plus
provider, age_s (Sekunden seit der Messung, leer wenn unbekannt) und source.
Gewinnt der neueste Eintrag, bei Gleichstand der genauere. Exit 1 = kein Standort.

Braucht keine App-Berechtigung: funktioniert auch, wenn Android 16 Termux:API
im Hintergrund den Standort verweigert.
"""
import json
import re
import sys

LOC_RE = re.compile(
    r"last location=Location\[(?P<provider>\w+) (?P<lat>-?\d+(?:\.\d+)?),(?P<lon>-?\d+(?:\.\d+)?)"
    r"(?:.*?hAcc=(?P<acc>\d+(?:\.\d+)?))?.*?et=\+(?P<et>[0-9dhms]+)"
)
ET_PART_RE = re.compile(r"(\d+)(ms|d|h|m|s)")
UNIT_SECONDS = {"d": 86400, "h": 3600, "m": 60, "s": 1, "ms": 0.001}


def et_seconds(text):
    """'+2d3h4m5s6ms' (ohne +) -> Sekunden seit Systemstart."""
    return sum(int(n) * UNIT_SECONDS[u] for n, u in ET_PART_RE.findall(text))


def parse(dump):
    for m in LOC_RE.finditer(dump):
        yield {
            "provider": m.group("provider"),
            "latitude": float(m.group("lat")),
            "longitude": float(m.group("lon")),
            "accuracy": float(m.group("acc")) if m.group("acc") else None,
            "et": et_seconds(m.group("et")),
        }


def best(locations):
    """Neuester Eintrag; bei gleichem Zeitpunkt der genauere."""
    return max(locations, key=lambda l: (l["et"], -(l["accuracy"] if l["accuracy"] is not None else 1e9)),
               default=None)


def main(argv):
    try:
        uptime = float(argv[1])
    except (IndexError, ValueError):
        uptime = None
    loc = best(list(parse(sys.stdin.read())))
    if loc is None:
        return 1
    age = round(uptime - loc["et"]) if uptime is not None else ""
    out = {k: loc[k] for k in ("latitude", "longitude", "accuracy", "provider")}
    out.update(age_s=age, source="dumpsys")
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
