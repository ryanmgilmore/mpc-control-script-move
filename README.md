# Ableton Move (Schwung): an MPC controller script

The MPC half of **[Move MPC Control](https://github.com/ryanmgilmore/move-mpc-control)**,
which turns an **Ableton Move** running **[Schwung](https://github.com/charlesvestal/schwung)**
into a pad controller, clip launcher, step sequencer, and Q-Link surface for an
**Akai MPC**, over one USB cable.

This repository is only the script the MPC runs: a controller script for the
Lua controller scripting that MPC 3.10 added, two files that the MPC loads
when the Move is plugged in. It does nothing on its own: the Move needs the
**Move MPC Control** Schwung module as well. **How to use it, every control, and
the Move's install steps are in the
[Move MPC Control README](https://github.com/ryanmgilmore/move-mpc-control#readme).**

> **Status: early.** Developed and tested on an **MPC Live II** running
> **MPC 3.10.1**. It needs nothing beyond stock MPC 3.10.1. Other MPC models
> are untested.

## What you need

- An Akai MPC on **MPC 3.10.1 or later**.
- A computer (Mac, Linux, or Windows) on the same network as the MPC, for the install.
- On the Move: Schwung and the **Move MPC Control** module
  ([install it](https://github.com/ryanmgilmore/move-mpc-control#1-the-move-module-this-repository)).

## Install

The script has to go in `MPC Documents/Devices/abletonMoveSchwung/` on the
MPC's **internal storage**. The MPC looks for controller scripts there, once,
when it starts, and nowhere else: not on an SD card, SSD, or USB stick.

On an MPC Live II, the only way in is the MPC's **developer mode**: its
internal storage is not shown to a computer in computer mode, and the MPC's
Browser neither shows these files nor copies folders.

1. **Download** the latest release from this repository's
   [releases](https://github.com/ryanmgilmore/mpc-control-script-move/releases)
   and unzip it. (Or clone the repository: the `abletonMoveSchwung` folder in
   it is the signed script.)
2. **Turn on developer mode** on the MPC, under Preferences > Enhancements.
   This starts an SSH server on the MPC.
3. **Find the MPC's IP address:** Preferences > Wi-Fi, then hold Shift and
   press Info. On Ethernet, the Ethernet tab.
4. **Run the installer** on a Mac or Linux computer, in the unzipped folder
   (on Windows, see [below](#on-windows)):

   ```sh
   sh install.sh 192.168.1.50      # the MPC's address; asked for if left out
   ```

   If you have set an SSH password in the MPC's developer settings, it asks
   for it once. It finds the MPC's internal storage, copies the folder, checks that both
   files arrived intact, and offers to restart the MPC software (an unsaved
   project is lost). The MPC reads scripts only when it starts.
5. **Turn developer mode off** again, or set an SSH password in the MPC's
   developer settings. By default its SSH has **no password**, so anyone on
   the network can log in while it is on.

Then plug the Move into a USB-A port on the MPC and open **Move MPC Control**
on the Move.

### On Windows

Windows 10 and 11 include an SSH client, so no extra software is needed.
Open **PowerShell**, go to the unzipped folder (`cd`), and run these two
commands with the MPC's address in place of `192.168.1.50` (steps 2 and 3
above give developer mode and the address):

```powershell
scp -r abletonMoveSchwung root@192.168.1.50:/tmp/
ssh root@192.168.1.50 "mkdir -p '/sdcard/MPC Documents/Devices' && rm -rf '/sdcard/MPC Documents/Devices/abletonMoveSchwung' && mv /tmp/abletonMoveSchwung '/sdcard/MPC Documents/Devices/'"
```

The first time, it asks whether to trust the MPC: type `yes`. It asks for no
password, unless you have set one in the MPC's developer settings. Then restart the MPC (switch it off and on), and turn developer mode
off. If Windows later refuses with "REMOTE HOST IDENTIFICATION HAS CHANGED",
run `ssh-keygen -R 192.168.1.50` and try again.

**With an app instead:** [WinSCP](https://winscp.net) (free). New site: file
protocol **SFTP**, host name the MPC's address, user name `root`, password
empty (or the one you set in the MPC's developer settings). Log in, open `/sdcard/MPC Documents/Devices` (create `Devices` if it is
missing), drag the `abletonMoveSchwung` folder into it, then restart the MPC.

**Removing on Windows:**
`ssh root@192.168.1.50 "rm -rf '/sdcard/MPC Documents/Devices/abletonMoveSchwung'"`,
or delete the folder in WinSCP, then restart the MPC.

These paths are for an MPC Live II (`/sdcard`). Other models keep
`MPC Documents` under `/nvme`, `/storage`, or `/data/UserData`.

### By hand on a Mac or Linux

Copy the `abletonMoveSchwung` folder to
`MPC Documents/Devices/` on the MPC's internal storage over developer mode's
SSH, for example
`scp -r abletonMoveSchwung "root@<address>:/sdcard/MPC Documents/Devices/"`.
The internal storage is `/sdcard` on an MPC Live II; other models use
`/nvme`, `/storage`, or `/data/UserData`. Then restart the MPC.

**Removing:** `sh install.sh --remove <address>`, or delete the
`abletonMoveSchwung` folder, then restart the MPC.

## Troubleshooting

If the Move says **No MPC**, the MPC is not answering. In order:

1. Is the Move connected to a USB-A **host** port on the MPC?
2. Was the MPC restarted after the install? Scripts are read once, at startup.
3. Are both files, with their original names, in
   `MPC Documents/Devices/abletonMoveSchwung/` on the internal storage?
4. Was `abletonMoveSchwung.lua` edited after it was signed? The MPC ignores a
   script whose checksum does not match its `.ini`, without saying so.
   Install the released files again, or re-sign (below).
5. Is the MPC on 3.10.1 or later?

If the Move says the script is **too new** or **too old**, the two halves are
different versions: update both. More in the
[Move MPC Control troubleshooting](https://github.com/ryanmgilmore/move-mpc-control/blob/main/guide/TROUBLESHOOTING.md).

## Changing the script

The `.ini` carries `checksum=`, the SHA-256 of the `.lua`'s bytes followed by
a salt. The salt is inMusic's, not this project's, so it is **not in this
repository**. The released `.ini` is already signed; only a changed `.lua`
needs signing again, with your own copy of the salt:

```sh
MPC_SALT=<the salt> python3 build.py
```

`salt.py` explains how to confirm a salt against Akai's own controller
scripts before trusting it.

Tests (Lua 5.4): `lua test/run.lua`. They run the script against a mock of
the MPC's scripting interface. `test/vectors.json` is a copy of the wire
protocol's examples from
[move-mpc-control](https://github.com/ryanmgilmore/move-mpc-control/blob/main/protocol/vectors.json);
keep the two in step.

## Changelog

Release this script and the [Move MPC Control](https://github.com/ryanmgilmore/move-mpc-control)
module at the same version: they refuse to connect across protocol versions.
The module's README has the full changelog.

### v0.3.0 (2026-11-23)

- Protocol 5: notes on steps from the Move (written into the MPC's selected
  clip, in either workflow), a new clip on a double tap, and Step Seq's knob
  parameter for the Move's screen.

### v0.2.0

Not released: its features ship in v0.3.0.

### v0.1.0 (2026-11-19)

First release.

## About this project

Move MPC Control and this script are designed and tested by Ryan Gilmore, on
the real hardware, and written with AI assistance. The design and the way it
feels to use are his decisions; every feature is tried by a person on an MPC
and a Move before it is called done.

It is not affiliated with or endorsed by Akai Professional, inMusic, or
Ableton. MPC, Q-Link, Ableton, and Move are trademarks of their owners.

## Licence

**GNU General Public License, version 3 or later** (`LICENSE`).
Copyright (C) 2026 Ryan Gilmore.
