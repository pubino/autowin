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

4. **Do not turn on the TPM by editing `config.plist`.** With `QEMU:TPMDevice` set there,
   Setup ran but the installed Windows hung at the firmware splash on every boot (CPU busy,
   no disk writes); without it, it booted at once. The answer file's LabConfig bypasses
   cover Windows 11's TPM check, and no TPM also means no automatic BitLocker.

5. **Two answer files conflict.** UTM's guest tools ISO has its own `Autounattend.xml`,
   and Windows Setup reads the file from the root of any removable disc. Ship one
   provisioning disc: the guest tools tree with your answer file replacing UTM's.

6. **Drive letters in Windows PE are not fixed.** Driver paths list `D:` to `F:`, and
   the first-logon command searches drives for `setup-guest.ps1`.

7. **A silent guest tools install can hang on a driver prompt.** The virtio drivers are
   signed by Red Hat; Windows asks "install this device software?" even with `/S`.
   `setup-guest.ps1` adds the signer of each ARM64 `.cat` file to `TrustedPublisher` first.

8. **Nobody can press "any key to boot from CD or DVD" through UTM.** UTM's AppleScript
   `input keystroke` returns success but the keys never reach a QEMU guest; the prompt
   times out and the firmware drops to `Shell>`. A `startup.nsh` on the provisioning disc
   does not help either: the firmware reads only FAT, not ISO 9660. Give the VM a QEMU
   monitor (gotcha 15) and send `sendkey spc` through it (`vm-keys.sh --any-key`). If the
   prompt was missed, type `fs0:\efi\boot\bootaa64.efi` at `Shell>` and press Space again.

9. **`status` is a read-only variable in zsh.** `if status=$(utmctl status …)` fails
   at runtime, not at `zsh -n`. Use another name.

10. **Variables set inside `$(…)` are lost.** A helper that records mounts for cleanup
    must not be called in a command substitution; return through `REPLY`.

11. **`utmctl exec` needs the guest agent.** It works only after the guest tools are
    installed (see 12 for how to tell).

12. **`utmctl exec` and `utmctl file` exit 0 when they fail.** Without a guest agent they
    print "The QEMU guest agent is not running…" and still return success, so an
    exit-code probe reports a fresh VM "ready" seconds after start. Require positive
    evidence: pull a marker file the guest wrote and check its content.

13. **An `EXIT` trap does not run when a zsh script is killed.** A stopped run left the
    Windows ISO mounted ("Resource busy" for the next one). Add
    `trap 'exit 130' INT TERM HUP` so signals go through the `EXIT` trap, and unmount the
    ISO as soon as it has been checked.

14. **UTM starts a new VM from its in-memory configuration.** Editing `config.plist` right
    after `make new virtual machine` changes nothing: the VM booted with empty CD drives
    (the firmware map showed only `BLK` devices, no `FS`). Run
    `reload configuration of virtual machine id …` after editing; it reports error -2700
    but applies the file. Then check with QEMU itself (`info block` on the monitor), not
    with the configuration.

15. **A QEMU monitor socket must live in UTM's group container, by relative path.** QEMU is
    sandboxed: binding inside the VM bundle fails ("Operation not permitted"). Its working
    directory is `~/Library/Group Containers/WDNLXAD4W8.com.utmapp.UTM`, so pass
    `-monitor unix:NAME.mon,server=on,wait=off`. An absolute path fails because UTM splits
    extra arguments at spaces ("Group Containers"). The same monitor gives screenshots:
    `screendump NAME.screen.ppm` (`vm-screen.sh`).

16. **Never send keys once Setup is installing.** Its focused button is Cancel. Stop
    pressing Space as soon as the VM disk grows (Setup is writing).

17. **A failed QEMU start shows "Internal error trying to connect to SPICE server".** It
    is a symptom: UTM's display could not connect because QEMU exited. The real error is
    in `utmctl start`'s output.

18. **`screendump` goes black once Windows' display driver takes over.** It shows the
    firmware and Setup, then only black frames while the UTM window shows Windows. Judge
    progress by disk activity (`info blockstats` on the monitor) as well.

19. **`utmctl exec` runs as SYSTEM, not as the logged-in user.** Fine for installers; anything
    that needs the desktop session (Office automation, GUI apps) must run in the user's
    session, for example through a scheduled task for that user.

20. **Do not edit a zsh script while it runs.** zsh reads scripts as it goes; a run that was
    waiting while its file changed failed at the end with `unmatched "`.
