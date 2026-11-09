#!/usr/bin/env python3
"""
Writes the GitHub release description from CHANGELOG.md.

    python3 .github/scripts/release_notes.py <version> [previous-release-version] > notes.md

Takes every changelog version newer than the previous release, up to and
including <version>, and groups the lines by section (New, Changed, Fixed).
With no previous release, only <version>'s entry is used.
Used by .github/workflows/release.yml; safe to run by hand to preview.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHANGELOG = ROOT / "CHANGELOG.md"
REPO_URL = "https://github.com/Kain-Mercer/KoS-Mod"


def version_key(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def parse(text):
    """[(version, [(title, [items])])] in file order (newest first)."""
    entries, version, title = [], None, None
    for line in text.splitlines():
        m = re.match(r"^##\s+v?([0-9][0-9.]*)\s*$", line)
        if m:
            version = m.group(1)
            entries.append((version, []))
            title = None
            continue
        m = re.match(r"^###\s+(.+?)\s*$", line)
        if m and version:
            title = m.group(1)
            entries[-1][1].append((title, []))
            continue
        m = re.match(r"^[-*]\s+(.+)$", line)
        if m and version and title:
            entries[-1][1][-1][1].append(m.group(1))
    return entries


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: release_notes.py <version> [previous-release-version]")
    version = sys.argv[1].lstrip("v")
    previous = sys.argv[2].lstrip("v") if len(sys.argv) > 2 and sys.argv[2] else None

    entries = parse(CHANGELOG.read_text(encoding="utf-8"))
    if version not in {v for v, _ in entries}:
        sys.exit("version %s has no entry in CHANGELOG.md" % version)

    chosen = [
        (v, s) for v, s in entries
        if version_key(v) <= version_key(version)
        and (version_key(v) > version_key(previous) if previous else v == version)
    ]

    order, grouped = [], {}
    for _, sections in chosen:
        for title, items in sections:
            if title not in grouped:
                order.append(title)
                grouped[title] = []
            grouped[title].extend(items)
    rank = {"New": 0, "Changed": 1, "Fixed": 2}
    order.sort(key=lambda t: rank.get(t, 3))
    heading = {"New": "New in this version", "Changed": "Changed", "Fixed": "Fixed"}

    out = []
    out.append("## Installing")
    out.append("1. Download the **BHG-Kill-List** zip below.")
    out.append("2. Unzip it and put the `BHG-Kill-List` folder in your WoW: Forever `Interface\\AddOns` folder.")
    out.append("3. Restart the game, then type `/kos` to open the list.")
    out.append("")
    out.append("Updating from an earlier version? Replace the `BHG-Kill-List` folder; your list and settings are kept.")
    out.append("")
    for title in order:
        out.append("## " + heading.get(title, title))
        for item in grouped[title]:
            out.append("- " + item)
        out.append("")
    out.append("More about what BH&G Kill List does is in the [README](%s#readme)." % REPO_URL)
    print("\n".join(out))


if __name__ == "__main__":
    main()
