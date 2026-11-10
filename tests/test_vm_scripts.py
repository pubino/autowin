"""The zsh scripts and guest files, run for real against fake hdiutil/uname/utmctl/osascript."""

from __future__ import annotations

import os
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
ZSH_DIR = ROOT / "examples" / "zsh"
GUEST = ROOT / "examples" / "guest"
NS = {"u": "urn:schemas-microsoft-com:unattend"}
ZSH = shutil.which("zsh")


def test_answer_file_is_complete_and_arm64_only() -> None:
    text = (GUEST / "autounattend.xml").read_text()
    root = ET.fromstring(text)  # well-formed
    comps = root.findall(".//u:component", NS)
    assert comps and {c.get("processorArchitecture") for c in comps} == {"arm64"}
    passes = {s.get("pass") for s in root.findall("u:settings", NS)}
    assert {"windowsPE", "specialize", "oobeSystem"} <= passes
    for needle in (
        "BypassTPMCheck",
        "BypassSecureBootCheck",
        "<WillWipeDisk>true</WillWipeDisk>",
        "<WillShowUI>Never</WillShowUI>",
        "<AcceptEula>true</AcceptEula>",
        "<HideOnlineAccountScreens>true</HideOnlineAccountScreens>",
        "setup-guest.ps1",
    ):
        assert needle in text, needle
    account = root.find(".//u:LocalAccount", NS)
    logon = root.find(".//u:AutoLogon", NS)
    assert account is not None and logon is not None
    assert (
        account.findtext("u:Name", namespaces=NS)
        == logon.findtext("u:Username", namespaces=NS)
        == "@@USER@@"
    )
    assert account.findtext("u:Group", namespaces=NS) == "Administrators"
    for el in (account, logon):
        assert el.findtext("u:Password/u:Value", namespaces=NS) == "@@PASSWORD@@"
    assert logon.findtext("u:Enabled", namespaces=NS) == "true"
    assert root.findtext(".//u:ComputerName", namespaces=NS) == "@@COMPUTER@@"
    image = root.find(".//u:InstallFrom/u:MetaData/u:Value", NS)
    assert image is not None and image.text == "Windows 11 Pro"


def _stubs(tmp_path: Path, *, arm64_iso: bool = True) -> tuple[dict[str, str], Path]:
    bin_dir, log = tmp_path / "bin", tmp_path / "calls.log"
    bin_dir.mkdir()
    files = 'mkdir -p "$m/sources"; : > "$m/sources/install.wim"'
    if arm64_iso:
        files += (
            '; mkdir -p "$m/efi/boot" "$m/efi/microsoft/boot"; : > "$m/efi/boot/bootaa64.efi"'
            '; : > "$m/efi/microsoft/boot/cdboot_noprompt.efi"'
        )
    stubs = {
        "uname": "echo arm64",
        # hdiutil attach ... -mountpoint M IMAGE: fake the ISO contents in M
        "hdiutil": f'echo "hdiutil $*" >> {log}; if [ "$1" = attach ]; then '
        'while [ $# -gt 0 ]; do [ "$1" = -mountpoint ] && m=$2; shift; done; ' + files + "; fi",
        "osascript": f'echo "osascript $*" >> {log}',
        "utmctl": f'echo "utmctl $*" >> {log}; '
        '[ "$1" = status ] && [ -n "$VM_STATUS" ] && echo "$VM_STATUS" && exit 0; '
        '[ "$1" = status ] && exit 1; exit 0',
    }
    for name, body in stubs.items():
        (bin_dir / name).write_text(f"#!/bin/sh\n{body}\n")
        (bin_dir / name).chmod(0o755)
    (tmp_path / "tools.iso").write_bytes(b"guest tools")
    (tmp_path / "win.iso").write_bytes(b"windows")
    env = {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "HOME": str(tmp_path),
        "TMPDIR": str(tmp_path),
        "UTMCTL": str(bin_dir / "utmctl"),
        "GUEST_TOOLS": str(tmp_path / "tools.iso"),
        "AUTOWIN_STATE": str(tmp_path / "state"),
        "UTM_DOCS": str(tmp_path / "docs"),
    }
    return env, log


def _zsh(script: str, *args: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    assert ZSH is not None, "zsh is required for these tests"
    return subprocess.run(
        [ZSH, "-f", str(ZSH_DIR / script), *args], capture_output=True, text=True, env=env
    )


def test_create_dry_run_changes_nothing(tmp_path: Path) -> None:
    env, log = _stubs(tmp_path)
    res = _zsh("vm-create.sh", "--dry-run", "--name", "t1", str(tmp_path / "win.iso"), env=env)
    assert res.returncode == 0, res.stderr
    assert "+ mkdir -p" in res.stdout and "make QEMU aarch64 VM t1" in res.stdout
    assert not (tmp_path / "state").exists()
    calls = log.read_text()
    assert "osascript" not in calls and "makehybrid" not in calls
    assert "utmctl start" not in calls
    assert (
        calls.count("hdiutil attach") == calls.count("hdiutil detach") == 1
    )  # the Windows ISO, read-only
    assert "-readonly" in calls


def test_create_refuses_an_iso_that_is_not_arm64(tmp_path: Path) -> None:
    env, log = _stubs(tmp_path, arm64_iso=False)
    res = _zsh("vm-create.sh", "--dry-run", str(tmp_path / "win.iso"), env=env)
    assert res.returncode != 0
    assert "not an Arm64 Windows ISO" in res.stderr
    assert "hdiutil detach" in log.read_text()  # unmounted on the way out


@pytest.mark.parametrize(
    ("args", "message"),
    [
        (["--name", "bad name"], "--name may use"),
        (["--memory", "lots"], "--memory must be a number"),
        (["--disk", "10"], "--disk must be at least 40"),
        ([], "Windows ISO not found"),
    ],
)
def test_create_validates_arguments(tmp_path: Path, args: list[str], message: str) -> None:
    env, _ = _stubs(tmp_path)
    iso = [str(tmp_path / "win.iso")] if args else []
    res = _zsh("vm-create.sh", "--dry-run", *args, *iso, env=env)
    assert res.returncode != 0
    assert message in res.stderr


def test_create_waits_for_an_existing_vm_instead_of_making_another(tmp_path: Path) -> None:
    env, log = _stubs(tmp_path)
    env["VM_STATUS"] = "stopped"
    res = _zsh("vm-create.sh", "--dry-run", "--name", "t1", str(tmp_path / "win.iso"), env=env)
    assert res.returncode == 0, res.stderr
    assert "already exists" in res.stdout
    assert "start t1" in res.stdout  # would start it (dry run prints)
    assert "make QEMU" not in res.stdout
    assert "osascript" not in log.read_text()


def test_destroy_dry_run_prints_and_keeps_everything(tmp_path: Path) -> None:
    env, log = _stubs(tmp_path)
    env["VM_STATUS"] = "started"
    state = tmp_path / "state" / "t1"
    state.mkdir(parents=True)
    res = _zsh("vm-destroy.sh", "--dry-run", "t1", env=env)
    assert res.returncode == 0, res.stderr
    assert "stop --kill t1" in res.stdout and "delete t1" in res.stdout and "rm -rf" in res.stdout
    assert state.exists()
    assert "utmctl delete" not in log.read_text() and "utmctl stop" not in log.read_text()


def test_destroy_deletes_vm_and_state(tmp_path: Path) -> None:
    env, log = _stubs(tmp_path)
    env["VM_STATUS"] = "stopped"
    state = tmp_path / "state" / "t1"
    state.mkdir(parents=True)
    res = _zsh("vm-destroy.sh", "--keep-license", "t1", env=env)
    assert res.returncode == 0, res.stderr
    assert "utmctl delete t1" in log.read_text()
    assert "utmctl stop" not in log.read_text()  # already stopped
    assert not state.exists()


def test_host_waits_for_the_markers_the_guest_writes() -> None:
    create = (ZSH_DIR / "vm-create.sh").read_text()
    guest = (GUEST / "setup-guest.ps1").read_text()
    for marker in ("C:\\autowin-setup.done", "C:\\autowin-setup.failed"):
        assert marker in create, marker
        assert f"'{marker}'" in guest, marker


def test_first_logon_runs_the_script_that_goes_on_the_disc() -> None:
    create = (ZSH_DIR / "vm-create.sh").read_text()
    answer = (GUEST / "autounattend.xml").read_text()
    assert 'cp "$guest/setup-guest.ps1" "$staging/disc/setup-guest.ps1"' in create
    assert r"if exist %d:\setup-guest.ps1" in answer
    assert '"$guest/autounattend.xml" > "$staging/disc/Autounattend.xml"' in create


def _waiting_env(tmp_path: Path, pull_output: str) -> tuple[dict[str, str], Path]:
    """An existing, started VM; `utmctl exec`/`file pull` behave like the real one without an agent:
    print an error and still exit 0."""
    env, log = _stubs(tmp_path)
    env["VM_STATUS"] = "started"
    fake = Path(env["UTMCTL"])
    fake.write_text(
        "#!/bin/sh\n"
        f'echo "utmctl $*" >> {log}\n'
        '[ "$1" = status ] && echo "$VM_STATUS" && exit 0\n'
        'if [ "$1" = file ] && [ "$2" = pull ]; then\n'
        '  case "$*" in *setup.done*) printf "%s" "$PULL_DONE";; esac\n'
        "  exit 0\n"
        "fi\n"
        'echo "The QEMU guest agent is not running or not installed on the guest." >&2\n'
        "exit 0\n"
    )
    env["PULL_DONE"] = pull_output
    return env, log


def test_a_guest_without_agent_is_not_reported_ready(tmp_path: Path) -> None:
    # Regression: utmctl exits 0 when the guest agent is missing; that was taken as "ready".
    env, _ = _waiting_env(tmp_path, pull_output="")
    res = _zsh("vm-create.sh", "--timeout", "0", "--name", "t1", str(tmp_path / "win.iso"), env=env)
    assert res.returncode != 0
    assert "timed out" in res.stderr
    assert "ready: " not in res.stdout


def test_ready_needs_the_marker_the_guest_wrote(tmp_path: Path) -> None:
    env, log = _waiting_env(tmp_path, pull_output="2026-11-10T14:05:31.1234567-05:00")
    res = _zsh("vm-create.sh", "--timeout", "1", "--name", "t1", str(tmp_path / "win.iso"), env=env)
    assert res.returncode == 0, res.stderr
    assert "ready: t1" in res.stdout
    assert "file pull" in log.read_text()


def test_create_drives_the_boot_through_the_qemu_monitor() -> None:
    # UTM's AppleScript keystrokes report success but never reach the guest; a startup.nsh on an
    # ISO cannot be read by the firmware. Keys go through the QEMU monitor instead.
    create = (ZSH_DIR / "vm-create.sh").read_text()
    assert "input keystroke" not in create and "startup.nsh" not in create
    assert "-monitor" in create and "unix:$name.mon,server=on,wait=off" in create
    # Regression: a 20 s burst right after start ended before the prompt appeared (end-to-end run,
    # 2026-11-10); recovery from Shell> then cost about 3 minutes.
    assert '--any-key 45 "$name"' in create
    assert r"fs0:\efi\boot\bootaa64.efi" in create
    assert not (GUEST / "startup.nsh").exists()


def test_create_reloads_the_config_and_checks_discs_with_qemu() -> None:
    # Regression: UTM started the VM from its in-memory configuration, with empty CD drives.
    create = (ZSH_DIR / "vm-create.sh").read_text()
    reload = create.index("reload configuration of virtual machine id")
    start = create.index('"$UTMCTL" start "$name"\n', reload)
    check = create.index('"info block"', start)
    assert reload < start < check
    assert "the VM started without its discs" in create


def test_create_stops_pressing_keys_once_setup_writes() -> None:
    # Space would press Setup's focused Cancel button once installation is under way.
    create = (ZSH_DIR / "vm-create.sh").read_text()
    loop = create[create.index("for attempt in 1 2 3; do") :]
    loop = loop[: loop.index("done\n    (( started ))")]
    assert loop.index("{ started=1; break; }") < loop.index("vm-keys.sh")
    assert "(( started )) && break" in loop


def test_the_windows_iso_is_unmounted_right_after_checking(tmp_path: Path) -> None:
    # A mount held for the whole (long) run keeps the ISO busy for anyone else.
    env, log = _stubs(tmp_path)
    res = _zsh("vm-create.sh", "--dry-run", "--name", "t1", str(tmp_path / "win.iso"), env=env)
    assert res.returncode == 0, res.stderr
    calls = log.read_text().splitlines()
    detach = next(i for i, c in enumerate(calls) if c.startswith("hdiutil detach"))
    status = next(i for i, c in enumerate(calls) if c.startswith("utmctl status"))
    assert detach < status


def test_create_leaves_the_tpm_off() -> None:
    # Regression: with QEMU:TPMDevice turned on in config.plist, the installer ran but the
    # installed Windows hung at the firmware splash on every boot. The answer file's LabConfig
    # bypass covers Windows 11's TPM check instead.
    create = (ZSH_DIR / "vm-create.sh").read_text()
    assert "TPMDevice true" not in create
    assert "BypassTPMCheck" in (GUEST / "autounattend.xml").read_text()


def test_create_reports_its_build_time() -> None:
    create = (ZSH_DIR / "vm-create.sh").read_text()
    assert "begin=$SECONDS" in create
    assert 'say "ready: $name is logged in as $VM_USER and answers utmctl exec (built in' in create


@pytest.mark.parametrize("script", ["vm-create.sh", "vm-office.sh", "vm-destroy.sh"])
def test_message_helpers_print_raw(script: str) -> None:
    # print without -r interprets backslash escapes, mangling Windows paths in messages.
    text = (ZSH_DIR / script).read_text()
    for helper in ("die()", "say()"):
        if helper in text:
            line = next(ln for ln in text.splitlines() if ln.startswith(helper))
            assert "print -r" in line or "print -ru2" in line, line
