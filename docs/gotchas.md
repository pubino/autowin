# Gotchas (learned the hard way)

Each of these cost a debugging session. Most now have a regression test in this repo.

1. **Microsoft blocks scripted ISO downloads.** The download page's API
   (`GetProductDownloadLinksBySku`) answers `Sentinel marked this request as rejected`
   to scripted clients. Download the Arm64 ISO in a browser; do not try to get around it.

2. **AppleScript cannot attach a disc image to a removable drive.** UTM's
   `make new virtual machine` accepts `source:` on a removable drive but ignores it:
   UTM keeps removable images as sandbox bookmarks that only its GUI creates. Put the
   image inside the VM bundle (`Data/`, an APFS clone costs no space) and name it in
   `config.plist` (`Drive:N:ImageName`). UTM picks the change up on the next start.

3. **`reload configuration` is refused (OSStatus -10004).** Edit `config.plist` while
   the VM is stopped and start it with `utmctl start`; no reload is needed.

4. **The AppleScript configuration has no TPM switch.** Set `QEMU:TPMDevice` in
   `config.plist`. The answer file also sets Windows Setup's LabConfig bypasses.

5. **Two answer files conflict.** UTM's guest tools ISO has its own `Autounattend.xml`,
   and Windows Setup reads the file from the root of any removable disc. Ship one
   provisioning disc: the guest tools tree with your answer file replacing UTM's.

6. **Drive letters in Windows PE are not fixed.** Driver paths list `D:` to `F:`, and
   the first-logon command searches drives for `setup-guest.ps1`.

7. **A silent guest tools install can hang on a driver prompt.** The virtio drivers are
   signed by Red Hat; Windows asks "install this device software?" even with `/S`.
   `setup-guest.ps1` adds the signer of each ARM64 `.cat` file to `TrustedPublisher` first.

8. **"Press any key to boot from CD or DVD" times out.** Send keystrokes for the first
   ~25 s (`input keystroke vm text " "`).

9. **`status` is a read-only variable in zsh.** `if status=$(utmctl status …)` fails
   at runtime, not at `zsh -n`. Use another name.

10. **Variables set inside `$(…)` are lost.** A helper that records mounts for cleanup
    must not be called in a command substitution; return through `REPLY`.

11. **`utmctl exec` needs the guest agent.** It answers only after the guest tools are
    installed, so it doubles as the "logged in and ready" probe.
