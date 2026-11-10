#!/usr/bin/env python3
"""
Builds K-UI: Forever's KoS module from this addon's files.

    python3 tools/build_kui.py <out KoS.lua> [<Media/KoS folder>]

Writes one file holding Core, Sync, Detect, Stats, UI and Commands (each
in its own do ... end block, sharing one namespace) and, when a folder is
given, copies the sounds into it. K-UI's copy keeps its list in
KainUIForeverKoSDB, plays its sounds from Kain-UI-Forever/Media/KoS, and
names its windows KainUIForeverKoS...; everything else is the same code,
so K-UI users and standalone users share one guild list.
"""
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "BHG-Kill-List"
FILES = ["Core.lua", "Sync.lua", "Detect.lua", "Stats.lua", "UI.lua", "Commands.lua"]

HEADER = """\
-- KoS.lua: the BH&G Kill List (kill-on-sight list shared with the guild,
-- nearby enemies, wins and losses) inside K-UI: Forever.
--
-- Built from the standalone addon (Kain-Mercer/KoS-Mod, version {version})
-- by its tools/build_kui.py. Edit the standalone files and rebuild rather
-- than editing this file, so the two never drift apart.
--
-- When the standalone addon is installed too, this module is in charge:
-- the standalone copy stays asleep and its list and records are brought
-- in here at login. /kos off turns this module off (the standalone addon
-- then takes over, if installed); /kos on turns it back on.

local ADDON_NAME, KUI = ...

local ns = {{
	embedded = true,
	DB_NAME = "KainUIForeverKoSDB",
	SOUND_DIR = "Interface\\\\AddOns\\\\Kain-UI-Forever\\\\Media\\\\KoS\\\\",
	FRAME_PREFIX = "KainUIForeverKoS",
	POPUP_PREFIX = "KAINUIFOREVER_KOS_",
}}
if type(KUI) == "table" then KUI.KoS = ns end
"""


def body(name, text):
    lines = text.splitlines()
    out = []
    for line in lines:
        if re.match(r"^local (ADDON_NAME|_), ns = \.\.\.\s*$", line):
            continue  # the shared ADDON_NAME and ns come from the header
        out.append(line)
    return "do -- " + name + "\n" + "\n".join(out).rstrip() + "\nend\n"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    toc = (ADDON / "BHG-Kill-List.toc").read_text(encoding="utf-8")
    version = re.search(r"^## Version:\s*(\S+)", toc, re.M).group(1)
    parts = [HEADER.format(version=version)]
    for f in FILES:
        parts.append(body(f, (ADDON / f).read_text(encoding="utf-8")))
    Path(sys.argv[1]).write_text("\n".join(parts), encoding="utf-8")
    if len(sys.argv) > 2:
        media = Path(sys.argv[2])
        media.mkdir(parents=True, exist_ok=True)
        for snd in sorted((ADDON / "Sounds").glob("*.mp3")):
            shutil.copy2(snd, media / snd.name)
    print("wrote", sys.argv[1], "from version", version)


if __name__ == "__main__":
    main()
