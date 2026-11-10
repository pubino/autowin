# autowin

Scripts, guidance and tests for **disposable Windows 11 (Arm64) VMs in
[UTM](https://mac.getutm.app)** on Apple Silicon. One command goes from a Windows ISO to a
booted, logged-in VM that the host can drive with `utmctl exec` and `utmctl file`, without
touching the installer. The companion to [automac](https://github.com/pubino/automac).

## Layout

| Path | What |
| --- | --- |
| [`examples/zsh/vm-create.sh`](examples/zsh/vm-create.sh) | Create, install, log in, install guest tools, wait until ready. |
| [`examples/zsh/vm-destroy.sh`](examples/zsh/vm-destroy.sh) | Delete the VM and its local state. |
| [`examples/guest/autounattend.xml`](examples/guest/autounattend.xml) | Unattended Windows Setup answer file (based on UTM's). |
| [`examples/guest/setup-guest.ps1`](examples/guest/setup-guest.ps1) | First-logon script: trust the driver publisher, install UTM guest tools silently. |
| [`docs/gotchas.md`](docs/gotchas.md) | Failures already debugged once. Read before debugging. |
| [`docs/for-agents.md`](docs/for-agents.md) | Entry point for agents pointed at this repository. |
| [`tests/`](tests/) | Tests that run the scripts against fake `hdiutil`, `uname`, `utmctl` and `osascript`: no VM needed. |

## Quick start

Requirements: Apple Silicon Mac, UTM 5 (opened once, so it has downloaded its guest tools),
about 70 GB free.

1. Download the Windows 11 Arm64 ISO in a browser from
   <https://www.microsoft.com/en-us/software-download/windows11arm64>
   (*Windows 11 (multi-edition ISO for Arm64)*). Microsoft refuses scripted downloads.
2. Create the VM:

   ```zsh
   examples/zsh/vm-create.sh --dry-run ~/Downloads/Win11_*_Arm64.iso
   examples/zsh/vm-create.sh ~/Downloads/Win11_*_Arm64.iso
   ```

   The first run asks once whether Terminal may control UTM. Installation takes 20-30
   minutes; watch it in the UTM window if you like.
3. Use it:

   ```zsh
   utmctl exec autowin --cmd cmd.exe /c ver
   utmctl file push autowin 'C:\Users\tester\in.txt' < in.txt
   ```

4. Throw it away: `examples/zsh/vm-destroy.sh autowin`.

**What the VM gets:** Windows 11 Pro installed with Microsoft's generic KMS client key (it
does not activate), a local administrator (`AUTOWIN_USER`, random password in
`AUTOWIN_STATE/NAME/password`) with automatic logon, no online-account screens, a virtual
TPM, and the UTM guest tools. Settings are in [`example.env`](example.env).

**Sensitive data:** take a snapshot of the clean, set-up VM, then run sessions that handle
data with `utmctl start --disposable`, so nothing is written to the VM's disk.

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
