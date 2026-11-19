#!/usr/bin/env python3
"""Summarise recent screen activity recorded by Claude Pulse.

Reads ~/Library/Application Support/ClaudePulse/activity/*.jsonl (written only while "Watch my
screen to suggest skills" is on) and prints one JSON document: time per app, the window titles
you keep coming back to, the app-to-app sequences you repeat, and a sample of the text that was
visible in the most repeated windows. Nothing leaves the machine; the output is there so a
Claude session can spot repeated manual workflows worth turning into skills.

    activity_stats.py [--days 7] [--titles 25] [--samples 3] [--chars 400]
"""
import argparse
import collections
import datetime
import glob
import json
import os
import re

DIRECTORY = os.path.expanduser("~/Library/Application Support/ClaudePulse/activity")


def normalise(title):
    """Fold counters and dates out of a title so 'Invoice 1042' and 'Invoice 1043' group together."""
    return re.sub(r"\d+", "#", title).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--titles", type=int, default=25, help="max repeated window titles to list")
    ap.add_argument("--samples", type=int, default=3, help="max text samples kept per title")
    ap.add_argument("--chars", type=int, default=400, help="max characters kept per text sample")
    args = ap.parse_args()

    first_day = (datetime.date.today() - datetime.timedelta(days=args.days - 1)).isoformat()
    entries = []
    for path in sorted(glob.glob(os.path.join(DIRECTORY, "*.jsonl"))):
        if os.path.basename(path)[:10] < first_day:
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry, dict) and entry.get("app"):
                    entries.append(entry)

    apps = collections.defaultdict(lambda: {"seconds": 0, "entries": 0, "days": set()})
    titles = collections.defaultdict(lambda: {"seconds": 0, "visits": 0, "days": set(), "examples": [], "samples": []})
    pairs = collections.Counter()
    triples = collections.Counter()
    switches = []  # the run of apps for one day, with repeats of the same app collapsed
    day = None
    previous_title = None

    def close_day():
        for i in range(len(switches) - 1):
            pairs[" → ".join(switches[i:i + 2])] += 1
        for i in range(len(switches) - 2):
            if len(set(switches[i:i + 3])) > 1:
                triples[" → ".join(switches[i:i + 3])] += 1
        switches.clear()

    for entry in entries:
        app = entry["app"]
        seconds = int(entry.get("seconds") or 0)
        entry_day = str(entry.get("at", ""))[:10]
        if entry_day != day:
            close_day()
            day = entry_day
            previous_title = None

        a = apps[app]
        a["seconds"] += seconds
        a["entries"] += 1
        a["days"].add(entry_day)
        if not switches or switches[-1] != app:
            switches.append(app)

        title = (entry.get("title") or "").strip()
        if not title:
            continue
        key = (app, normalise(title))
        t = titles[key]
        t["seconds"] += seconds
        t["days"].add(entry_day)
        # Consecutive entries for one window are one visit that lasted longer.
        if key != previous_title:
            t["visits"] += 1
        previous_title = key
        if title not in t["examples"] and len(t["examples"]) < 3:
            t["examples"].append(title)
        text = (entry.get("text") or "").strip()
        if text and len(t["samples"]) < args.samples and text[:args.chars] not in t["samples"]:
            t["samples"].append(text[:args.chars])
    close_day()

    repeated = sorted(titles.items(), key=lambda kv: (-kv[1]["visits"], -kv[1]["seconds"]))
    out = {
        "generatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "windowDays": args.days,
        "entries": len(entries),
        "totalMinutes": round(sum(a["seconds"] for a in apps.values()) / 60),
        "apps": [
            {"app": name, "minutes": round(a["seconds"] / 60), "entries": a["entries"], "days": len(a["days"])}
            for name, a in sorted(apps.items(), key=lambda kv: -kv[1]["seconds"])
        ],
        "repeatedWindows": [
            {"app": app, "title": pattern, "visits": t["visits"], "minutes": round(t["seconds"] / 60),
             "days": len(t["days"]), "examples": t["examples"], "textSamples": t["samples"]}
            for (app, pattern), t in repeated[:args.titles] if t["visits"] > 1
        ],
        "appSequences": {
            "pairs": [{"sequence": s, "count": n} for s, n in pairs.most_common(15) if n > 1],
            "triples": [{"sequence": s, "count": n} for s, n in triples.most_common(15) if n > 1],
        },
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
