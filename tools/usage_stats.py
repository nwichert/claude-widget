#!/usr/bin/env python3
"""Summarise recent Claude Code activity from local transcripts.

Reads ~/.claude/projects/*/*.jsonl and prints one JSON document: exact counts per project
(sessions, prompts, output tokens), which tools, connectors, skills and shell commands were
used, and a sample of the prompts you typed. Nothing leaves the machine; the prompt sample is
there so a Claude session can spot repeated workflows worth turning into skills.

    usage_stats.py [--days 14] [--prompts 180] [--chars 200]
"""
import argparse
import collections
import glob
import json
import os
import re
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--prompts", type=int, default=180, help="max prompts to include in the sample")
    ap.add_argument("--chars", type=int, default=200, help="max characters kept per prompt")
    args = ap.parse_args()

    since = time.time() - args.days * 86400
    files = [f for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
             if os.path.getmtime(f) >= since]

    projects = collections.defaultdict(lambda: {"sessions": 0, "prompts": 0, "outputTokens": 0, "lastActive": 0})
    tools = collections.Counter()
    connectors = collections.Counter()
    skills = collections.Counter()
    shell = collections.Counter()
    prompts = []

    for path in files:
        project = None
        title = None
        usage = {}          # message id -> output tokens (a streamed reply is logged more than once)
        session_prompts = 0
        with open(path, errors="ignore") as fh:
            for line in fh:
                # Cheap filter before paying for a JSON parse; transcripts hold large tool results.
                if not ('"type":"user"' in line or '"tool_use"' in line or '"usage"' in line
                        or '"custom-title"' in line):
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                kind = d.get("type")
                if kind == "custom-title":
                    title = d.get("customTitle")
                    continue
                if d.get("isSidechain"):
                    continue
                if project is None and d.get("cwd"):
                    project = os.path.basename(d["cwd"].rstrip("/"))
                msg = d.get("message") or {}
                content = msg.get("content")
                if kind == "user" and not d.get("isMeta"):
                    text = None
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list) and not any(b.get("type") == "tool_result" for b in content):
                        text = " ".join(b.get("text", "") for b in content if b.get("type") == "text")
                    if text:
                        text = re.sub(r"<[a-z-]+>.*?</[a-z-]+>", " ", text, flags=re.S)  # injected reminders
                        text = re.sub(r"\s+", " ", text).strip()
                        if len(text) >= 8 and not text.startswith("[") and "task-notification" not in text:
                            session_prompts += 1
                            prompts.append({"project": project or "?", "session": title or "",
                                            "at": d.get("timestamp", "")[:10], "text": text[:args.chars]})
                elif kind == "assistant":
                    u = msg.get("usage") or {}
                    if msg.get("id"):
                        usage[msg["id"]] = u.get("output_tokens", 0)
                    for b in content if isinstance(content, list) else []:
                        if b.get("type") != "tool_use":
                            continue
                        name = b.get("name", "")
                        if name.startswith("mcp__"):
                            tools["connector call"] += 1
                            connectors[name.split("__")[1]] += 1
                        else:
                            tools[name] += 1
                        inp = b.get("input") or {}
                        if name == "Skill" and inp.get("skill"):
                            skills[inp["skill"]] += 1
                        if name == "Bash":
                            cmd = re.sub(r"^(cd [^;&]+(&&|;)\s*)+", "", str(inp.get("command", "")).strip())
                            words = cmd.split()
                            if words:
                                head = os.path.basename(words[0])
                                if head in ("git", "gh", "npm", "npx", "firebase", "swift", "eas", "pnpm", "yarn") and len(words) > 1:
                                    head += " " + words[1]
                                shell[head] += 1
        if project is None:
            continue
        p = projects[project]
        p["sessions"] += 1
        p["prompts"] += session_prompts
        p["outputTokens"] += sum(usage.values())
        p["lastActive"] = max(p["lastActive"], os.path.getmtime(path))

    # Keep the newest prompts, spread across projects rather than all from the busiest one.
    prompts.sort(key=lambda r: r["at"], reverse=True)
    per_project = max(12, args.prompts // max(1, len(projects)))
    seen = collections.Counter()
    sample = []
    for r in prompts:
        if seen[r["project"]] < per_project and len(sample) < args.prompts:
            seen[r["project"]] += 1
            sample.append(r)

    out = {
        "windowDays": args.days,
        "totals": {"sessions": sum(p["sessions"] for p in projects.values()),
                   "prompts": sum(p["prompts"] for p in projects.values()),
                   "outputTokens": sum(p["outputTokens"] for p in projects.values())},
        "projects": sorted(({"name": k, **v, "lastActive": time.strftime("%Y-%m-%d", time.localtime(v["lastActive"]))}
                            for k, v in projects.items()), key=lambda r: -r["outputTokens"]),
        "tools": tools.most_common(15),
        "connectors": connectors.most_common(15),
        "skillsUsed": skills.most_common(20),
        "shellCommands": shell.most_common(25),
        "promptSample": sample,
    }
    print(json.dumps(out, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
