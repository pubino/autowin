# For agents

Use this repository when a task needs Windows on an Apple Silicon Mac: running a Windows-only
tool (Microsoft Access, Office automation, installers), testing a Windows build, or anything
that needs a clean, throwaway Windows machine.

1. Read [`gotchas.md`](gotchas.md) before debugging anything.
2. Get the Windows 11 Arm64 ISO with [fetchwin](https://github.com/pubino/fetchwin)
   (`fetchwin fetch --updates download`; it uses Microsoft's public ESD catalog), or ask the
   user to download it in a browser. Do not script Microsoft's download page (gotcha 1).
3. Run `examples/zsh/vm-create.sh --dry-run ISO`, then without `--dry-run`. It returns when
   the guest is logged in and `utmctl exec NAME --cmd …` works (20-30 minutes).
4. Drive the guest with `utmctl exec` and move files with `utmctl file push|pull`.
5. Sign-ins (Microsoft 365, other accounts) happen in the VM window; ask the user.
6. Keep sensitive data out of the persistent disk: snapshot a clean state and run data
   sessions with `utmctl start --disposable`.
7. `examples/zsh/vm-destroy.sh NAME` deletes the VM and its local state; there is no undo.
8. Before a user wipes or replaces their Mac, follow the README's "Rebuilding or replacing the
   host": VMs and their state (`AUTOWIN_STATE`) are not in the repository. If `vm-destroy.sh`
   reports "no local state", ask the user whether the VM is a clone before choosing
   `--release-license` or `--keep-license`.
