# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Ryan Gilmore
"""The salt for a controller script's .ini checksum: SHA-256(lua bytes + salt).

The salt is inMusic's, and is not part of any public copy of this project.
Resolution, first match wins:

  1. MPC_SALT in the environment (36 ASCII characters).
  2. The file named by MPC_SALT_FILE, else salt.private beside this file
     (git ignores it).

If neither is set, building fails with how to supply one. When Akai's own
shipped MPK mini IV pair is on disk (the folder MPC_SALT_CHECK_DIR names: copy
mpkMiniMkIV.ini and .lua from /usr/share/Akai/SME0/Devices/Akai on an MPC), the
salt is checked against its checksum line first: a wrong salt makes the MPC
drop the script silently.
"""
import hashlib
import os
import pathlib
import sys

SALT_LEN = 36
HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_FILE = HERE / "salt.private"
DEFAULT_CHECK_DIR = HERE / "akai-check"   # only if MPC_SALT_CHECK_DIR is unset; absent by default


def _die(msg):
    sys.exit(f"salt: {msg}")


def _check(salt):
    d = pathlib.Path(os.environ.get("MPC_SALT_CHECK_DIR", DEFAULT_CHECK_DIR))
    ini, lua = d / "mpkMiniMkIV.ini", d / "mpkMiniMkIV.lua"
    if not (ini.is_file() and lua.is_file()):
        return
    want = None
    for line in ini.read_text().splitlines():
        k, _, v = line.partition("=")
        if k.strip().lower() == "checksum":
            want = v.strip().lower()
    got = hashlib.sha256(lua.read_bytes() + salt).hexdigest()
    if want and got != want:
        _die(f"salt does not reproduce the checksum of {ini}; it is wrong")


def resolve():
    """Return the salt as bytes, or exit with instructions."""
    env = os.environ.get("MPC_SALT")
    if env is not None:
        raw, where = env.strip(), "MPC_SALT"
    else:
        path = pathlib.Path(os.environ.get("MPC_SALT_FILE", DEFAULT_FILE))
        if not path.is_file():
            _die(
                "no salt. Set MPC_SALT to the 36-character checksum salt of MPC 3.10.1's "
                "controller scripts, or put it in salt.private (or MPC_SALT_FILE). "
                "It can be confirmed against any of Akai's own .ini/.lua pairs: "
                "checksum = sha256(lua bytes + salt)."
            )
        raw, where = path.read_text().strip(), str(path)
    try:
        salt = raw.encode("ascii")
    except UnicodeEncodeError:
        _die(f"{where}: the salt must be ASCII")
    if len(salt) != SALT_LEN:
        _die(f"{where}: the salt is {len(salt)} characters, expected {SALT_LEN}")
    _check(salt)
    return salt
