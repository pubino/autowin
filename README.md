# autowin

Scripts, guidance and tests for **disposable Windows 11 (Arm64) VMs in
[UTM](https://mac.getutm.app)** on Apple Silicon. One command goes from a Windows ISO to a
booted, logged-in VM that the host can drive with `utmctl exec` and `utmctl file`, without
touching the installer. The companion to [automac](https://github.com/pubino/automac);
[fetchwin](https://github.com/pubino/fetchwin) gets the ISO from the terminal.

## Layout

| Path | What |
| --- | --- |
| [`examples/zsh/vm-create.sh`](examples/zsh/vm-create.sh) | Create, install, log in, install guest tools, wait until ready. |
| [`examples/zsh/vm-destroy.sh`](examples/zsh/vm-destroy.sh) | Release the VM's Microsoft 365 license, then delete the VM and its local state. |
| [`examples/zsh/vm-clone.sh`](examples/zsh/vm-clone.sh) | Clone a stopped VM with its own monitor socket and MAC address; records lineage. |
| [`examples/guest/release-office.ps1`](examples/guest/release-office.ps1) | The guest side of the license release (Microsoft's reset-activation steps). |
| [`examples/zsh/vm-ps.sh`](examples/zsh/vm-ps.sh) | Run PowerShell in the guest and print its output (exit 1 if it threw); `--user` runs it in the user's desktop session, e.g. for Office automation. |
| [`examples/zsh/vm-office.sh`](examples/zsh/vm-office.sh) | Install Microsoft 365 Apps with only the apps named (e.g. Access); activation is a sign-in. |
| [`examples/guest/install-office.ps1`](examples/guest/install-office.ps1) | The guest side: Office Deployment Tool (signature-checked), silent install, marker files. |
| [`examples/zsh/vm-keys.sh`](examples/zsh/vm-keys.sh) | Type into the VM through its QEMU monitor (UTM's AppleScript keystrokes never arrive). |
| [`examples/zsh/vm-screen.sh`](examples/zsh/vm-screen.sh) | Save a PNG screenshot of the VM's display. |
| [`examples/zsh/monitor.zsh`](examples/zsh/monitor.zsh) | Shared QEMU monitor helpers. |
| [`examples/tools/ppm2png.py`](examples/tools/ppm2png.py) | Screenshot converter (standard library only). |
| [`examples/guest/autounattend.xml`](examples/guest/autounattend.xml) | Unattended Windows Setup answer file (based on UTM's). |
| [`examples/guest/setup-guest.ps1`](examples/guest/setup-guest.ps1) | First-logon script: trust the driver publisher, install UTM guest tools silently; start the optional update install. |
| [`examples/guest/apply-updates.ps1`](examples/guest/apply-updates.ps1) | Optional: installs [fetchwin](https://github.com/pubino/fetchwin)'s update packages from a startup task, restarting as needed. |
| [`docs/gotchas.md`](docs/gotchas.md) | Failures already debugged once. Read before debugging. |
| [`docs/for-agents.md`](docs/for-agents.md) | Entry point for agents pointed at this repository. |
| [`tests/`](tests/) | Tests that run the scripts against fake `hdiutil`, `uname`, `utmctl`, `osascript` and a fake QEMU monitor: no VM needed. |

## Quick start

Requirements: Apple Silicon Mac, UTM 5 (opened once, so it has downloaded its guest tools),
about 70 GB free.

1. Get a Windows 11 Arm64 ISO, either way:
   - From the terminal with [fetchwin](https://github.com/pubino/fetchwin):
     `fetchwin fetch --out ~/Downloads` builds one from Microsoft's public ESD catalog (the
     one the Media Creation Tool reads), checked against the catalog's hashes. Add `--updates download` for the latest updates (below).
   - In a browser from
     <https://www.microsoft.com/en-us/software-download/windows11arm64>
     (*Windows 11 (multi-edition ISO for Arm64)*). That page refuses scripted downloads
     (gotcha 1).
2. Create the VM:

   ```zsh
   examples/zsh/vm-create.sh --dry-run ~/Downloads/Win11_*_Arm64.iso
   examples/zsh/vm-create.sh ~/Downloads/Win11_*_Arm64.iso
   ```

   **Optional, latest updates:** `fetchwin fetch --updates download` builds the ISO from
   Microsoft's catalog and leaves the latest cumulative update packages in a `.updates` folder
   beside it. `vm-create.sh` finds
   that folder by default, puts it on the provisioning disc, and the VM installs it after first
   logon (restarting on its own); `vm-create.sh` returns once it is done. `--updates DIR` names
   another folder, `--no-updates` skips it, `--updates-timeout MIN` (default 120) bounds the wait.
   If the updates fail, the VM is still usable; the message says which logs to read.
   Measured 2026-11-12 (26H2 Arm64, 26300.9711 to 26300.9974, 4 packages, 5 GB): **18m 17s**
   from ISO to an updated, logged-in VM, of which the updates took about 9 minutes (2.5 min
   checking the packages, 5 min DISM, one restart).

   The first run asks once whether Terminal may control UTM. Installation takes 20-30
   minutes; watch it in the UTM window if you like.
3. Use it:

   ```zsh
   examples/zsh/vm-ps.sh autowin 'Get-ComputerInfo | Select-Object OsName, OsArchitecture'
   utmctl file push autowin 'C:\Users\tester\in.txt' < in.txt
   examples/zsh/vm-office.sh --apps Access autowin   # then sign in once in the VM window
   ```

   Look at it or type into it from the host, for example to get past a screen the
   scripts did not expect:

   ```zsh
   examples/zsh/vm-screen.sh autowin screen.png
   examples/zsh/vm-keys.sh autowin 'some text'
   ```

4. Throw it away: `examples/zsh/vm-destroy.sh autowin`.

**Build time** (measured 2026-11-10 on an Apple M-series Mac with 128 GB RAM: UTM 5.0.8, Windows 11
24H2 Arm64 build 26100.4349, default 8 GB / 4 CPUs / 64 GB; `vm-create.sh` prints its own time):

| Step | Elapsed |
| --- | --- |
| Start to Windows Setup writing to disk | 4m 09s (about 3 min of it recovering a missed boot prompt; since fixed) |
| Setup, restarts, first logon, guest tools | 6m 30s |
| **Total, ISO to logged-in VM that answers `utmctl exec`** | **10m 39s** (first run); **7m 25s** after the boot-prompt fix |

Installing Access (`vm-office.sh --apps Access`, same day): downloading Office's 2.8 GB source
took about 9 minutes (roughly 5 MB/s through Delivery Optimization; the 467 MB ARM64 package over
HTTPS in 18 s, see gotcha 31), and installing from the local source about 1 minute.

**What the VM gets:** Windows 11 Pro installed with Microsoft's generic KMS client key (it
does not activate), a local administrator (`AUTOWIN_USER`, random password in
`AUTOWIN_STATE/NAME/password`) with automatic logon, no online-account screens, a virtual
TPM, and the UTM guest tools. Settings are in [`example.env`](example.env).

**Licenses, clones and teardown:** activate Office once in a VM (sign in), stop it, and
`vm-clone.sh` it into a base; work in further clones of that base. A clone shares its source's
Windows and Office device identity, so:

- `vm-destroy.sh NAME` releases the Microsoft 365 license inside Windows before deleting the VM
  (account sign-out from the Web Account Manager, cached licenses and identities removed, then
  checked). It starts a stopped VM for this. If the release fails, nothing is deleted.
- It keeps the license for a clone, and for a VM that has clones, because releasing it would
  sign the others out too. `--release-license` and `--keep-license` override this.
- A local release removes the license from the VM. Microsoft's account device list is the
  authoritative record: check it after deleting the last VM that held a license.

**Sensitive data:** take a snapshot of the clean, set-up VM, then run sessions that handle
data with `utmctl start --disposable`, so nothing is written to the VM's disk.

## Rebuilding or replacing the host

The repository holds everything needed to rebuild. The VMs and their state do not live in it:

| Lives only on this Mac | Where |
| --- | --- |
| VMs: disks, snapshots, Windows and Office activation | `~/Library/Containers/com.utmapp.UTM/Data/Documents/NAME.utm` |
| Per-VM state: password, clone lineage (`clone-of`) | `AUTOWIN_STATE/NAME` (default `~/Library/Application Support/autowin/NAME`) |
| Your settings | `.env` (gitignored; copy from `example.env`) |
| The Windows ISO (and fetchwin's `.updates` folder) | wherever you saved it; fetch it again with [fetchwin](https://github.com/pubino/fetchwin) or in a browser |

**Before wiping or replacing the Mac**, do one of these for every VM that holds a Microsoft 365
license:

- **Throw it away:** `vm-destroy.sh NAME`. Destroy clones first (they keep the license), then
  the base: with no clones left it releases the license by default.
- **Keep it:** stop it and back up its `NAME.utm` bundle **and** the whole `AUTOWIN_STATE`
  directory together. Lineage is only in `AUTOWIN_STATE`. A bundle restored without it looks
  like a standalone VM, so `vm-destroy.sh` refuses to guess and asks for `--release-license`
  or `--keep-license`.

If the Mac is already gone with a licensed VM on it, sign that device out in the Microsoft
account's device list; nothing on a new Mac can release it.

**On the new Mac:** install UTM 5 and open it once, clone this repository (and [fetchwin](https://github.com/pubino/fetchwin) if
you use it), recreate `.env` if you used one, and either restore the backups to the same paths
(then `utmctl list` should show the VMs) or run `vm-create.sh` again. For development, also install `uv`, Docker and
`docker-compose`.

## Developing this repo

```zsh
./scripts/test.sh            # lint, types, tests in Docker (docker-compose)
./scripts/test.sh --local    # same in .venv (uv sync)
```

Everything is tested against fakes, so CI needs neither a Mac nor a VM. Skipped tests fail
the run.

## License

[MIT](LICENSE). Windows and UTM are licensed separately; Windows needs its own license to
activate.
