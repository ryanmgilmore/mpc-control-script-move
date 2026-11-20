#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Ryan Gilmore
"""Sign the controller script: write abletonMoveSchwung/abletonMoveSchwung.ini.

Usage: python3 build.py ["<port name>[,alias...]"]
       default port: "Ableton Move Standalone Port"

You only need this after changing abletonMoveSchwung.lua: the .ini in this
repository is already signed for the .lua beside it. The MPC accepts a script
only if the .ini's checksum is SHA-256(the .lua's bytes + a salt that is
inMusic's, not this project's), and ignores it silently otherwise. The salt is
not published here: give your own copy in MPC_SALT (or in salt.private, or the
file MPC_SALT_FILE names). salt.py says how to check it against Akai's own
scripts.
"""
import hashlib
import pathlib
import sys

import salt

DEFAULT_PORT = "Ableton Move Standalone Port"
STEM = "abletonMoveSchwung"  # the script's table name and file stem: must match

here = pathlib.Path(__file__).resolve().parent
port = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PORT
if "\n" in port or not port.strip():
    sys.exit("build.py: bad port name")

folder = here / STEM
lua = (folder / f"{STEM}.lua").read_bytes()
checksum = hashlib.sha256(lua + salt.resolve()).hexdigest()

ini = (
    "[info]\n"
    "; Ableton Move (Schwung): the Move, running the Move MPC Control module, as pads, clips, steps and Q-Links\n"
    "device=Ableton Move (Schwung)\n"
    "manufacturer=Ableton\n"
    f"input={port}\n"
    f"output={port}\n"
    f"script={STEM}.lua\n"
    "scriptVersion=1.0\n"
    f"checksum={checksum}\n"
)
(folder / f"{STEM}.ini").write_text(ini)
print(f"{folder}/{STEM}.ini  port={port!r}")
print(f"checksum={checksum}")
