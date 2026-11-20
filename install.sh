#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Ryan Gilmore
# Install (or remove) the Ableton Move (Schwung) controller script on an MPC,
# over the SSH that the MPC's developer mode starts. Nothing is built: the folder
# next to this script is already signed. Needs a Mac or Linux computer on the
# same network as the MPC.
#
#   sh install.sh [MPC address]           install, then offer to restart MPC
#   sh install.sh --remove [MPC address]  remove it again
#
# The address can also come from MPC_ADDRESS. Without one, the script says
# where to find it and asks.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src="$here/abletonMoveSchwung"
remove=0
if [ "${1:-}" = "--remove" ]; then remove=1; shift; fi
case "${1:-}" in -h|--help) sed -n '4,13p' "$0"; exit 0 ;; esac

if [ "$remove" = 0 ] && { [ ! -f "$src/abletonMoveSchwung.ini" ] || [ ! -f "$src/abletonMoveSchwung.lua" ]; }; then
    echo "install.sh: the abletonMoveSchwung folder (abletonMoveSchwung.ini and .lua) must be next to this script." >&2
    exit 1
fi

addr=${1:-${MPC_ADDRESS:-}}
if [ -z "$addr" ]; then
    cat <<'EOF'
On the MPC, first turn on developer mode under Preferences > Enhancements.

The MPC's IP address: Preferences > Wi-Fi, then hold Shift and press Info.
(On Ethernet, the Ethernet tab; or look it up in your router.)
EOF
    printf 'MPC IP address: '
    read -r addr || addr=""
fi
[ -n "$addr" ] || { echo "install.sh: no address given." >&2; exit 1; }

# Developer mode's SSH logs in as root, with no password unless one is set in
# the MPC's developer settings (then ssh asks once), and its host key
# changes each time it starts, so no host-key check (as Akai's own Plugin SDK
# tool does). One connection is shared by the steps below.
tmp=$(mktemp -d)
trap 'ssh -o ControlPath="$tmp/cm" -O exit "root@$addr" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
# mpc_in passes this script's input through (the file copy); mpc gives ssh
# none, so it cannot swallow what the user types at a prompt.
mpc_in() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=8 -o NumberOfPasswordPrompts=1 \
        -o ControlMaster=auto -o ControlPath="$tmp/cm" -o ControlPersist=60 \
        "root@$addr" "$@"
}
mpc() { mpc_in "$@" < /dev/null; }

if ! mpc true; then
    cat >&2 <<EOF
install.sh: could not reach the MPC at $addr.
 - Is developer mode on? (Preferences > Enhancements)
 - Is the address right, and is this computer on the same network?
 - If you set an SSH password in the MPC's developer settings, was it typed right?
EOF
    exit 1
fi

# The MPC's internal storage, which holds "MPC Documents": /sdcard on an MPC
# Live II; other models use another of these. Scripts load only from here.
root=$(mpc 'for r in /sdcard /nvme /storage /data/UserData; do if [ -d "$r/MPC Documents" ]; then echo "$r"; break; fi; done')
if [ -z "$root" ]; then
    echo "install.sh: no 'MPC Documents' folder found on the MPC's internal storage." >&2
    exit 1
fi
dest="$root/MPC Documents/Devices/abletonMoveSchwung"

restart_mpc() {
    printf 'Restart the MPC software now? An unsaved project is lost. [y/N] '
    read -r ok || ok=""
    case "$ok" in
        y|Y|yes)
            mpc 'systemctl restart acvs 2>/dev/null || systemctl restart inmusic-mpc'
            echo "MPC restarting." ;;
        *) echo "Restart the MPC when you are ready: it loads scripts only when it starts." ;;
    esac
}

if [ "$remove" = 1 ]; then
    mpc "rm -rf '$dest' && sync"
    echo "Removed $dest."
    restart_mpc
    echo "Turn developer mode off again when you are done."
    exit 0
fi

# COPYFILE_DISABLE: no macOS "._" files, which the MPC would try to read as
# scripts. ._* removed on the MPC as well, in case.
COPYFILE_DISABLE=1 tar -C "$here" -cf - abletonMoveSchwung/abletonMoveSchwung.ini abletonMoveSchwung/abletonMoveSchwung.lua |
    mpc_in "mkdir -p '$root/MPC Documents/Devices' && tar -o -C '$root/MPC Documents/Devices' -xf - && rm -f '$dest'/._* && sync"

sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
for f in abletonMoveSchwung.ini abletonMoveSchwung.lua; do
    want=$(sum "$src/$f")
    got=$(mpc "sha256sum '$dest/$f'" | cut -d' ' -f1)
    if [ "$want" != "$got" ]; then
        echo "install.sh: $f did not arrive intact; run the script again." >&2
        exit 1
    fi
done
echo "Installed to $dest."
restart_mpc
echo "Turn developer mode off again when you are done, or set an SSH password in its settings."
