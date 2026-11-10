"""vm-ps.sh and vm-office.sh against a fake utmctl with a fake guest file system."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
ZSH_DIR = ROOT / "examples" / "zsh"
FAKE = ROOT / "tests" / "fakes" / "utmctl_guest.py"
ZSH = shutil.which("zsh")


@pytest.fixture
def guest(tmp_path: Path) -> tuple[Path, dict[str, str]]:
    store = tmp_path / "guest"
    store.mkdir()
    env = {**os.environ, "UTMCTL": str(FAKE), "FAKE_GUEST": str(store)}
    return store, env


def _run(script: str, *args: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    assert ZSH is not None, "zsh is required for these tests"
    return subprocess.run(
        [ZSH, "-f", str(ZSH_DIR / script), *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
    )


def _files(store: Path) -> list[str]:
    return sorted(p.name for p in store.iterdir() if p.name != "_calls.log")


def test_vm_ps_prints_output_and_cleans_up(guest: tuple[Path, dict[str, str]]) -> None:
    store, env = guest
    res = _run("vm-ps.sh", "vm1", "Get-Date", env=env)
    assert res.returncode == 0, res.stderr
    assert res.stdout.strip() == "guest says hi"  # BOM and CR removed
    assert _files(store) == []  # result files deleted in the guest
    assert "-EncodedCommand" in (store / "_calls.log").read_text()


def test_vm_ps_reports_a_throw(guest: tuple[Path, dict[str, str]]) -> None:
    _, env = guest
    res = _run("vm-ps.sh", "vm1", 'throw "no"', env=env)
    assert res.returncode == 1
    assert "ERROR" in res.stdout


def test_vm_ps_without_agent_times_out_instead_of_succeeding(
    guest: tuple[Path, dict[str, str]],
) -> None:
    _, env = guest
    res = _run("vm-ps.sh", "--timeout", "2", "vm1", "Get-Date", env={**env, "FAKE_SILENT": "1"})
    assert res.returncode == 1
    assert "no result after 2s" in res.stderr


def test_vm_office_installs_and_lists_the_apps(guest: tuple[Path, dict[str, str]]) -> None:
    store, env = guest
    res = _run("vm-office.sh", "--apps", "Access,Excel", "vm1", env=env)
    assert res.returncode == 0, res.stderr
    assert "installed in" in res.stdout
    assert "  Access=C:\\Program Files" in res.stdout and "  Excel=C:\\Program Files" in res.stdout
    pushed = (store / "C__autowin-office_install-office.ps1").read_bytes()
    assert pushed == (ROOT / "examples/guest/install-office.ps1").read_bytes()
    assert (store / "C__autowin-office.args").read_text() == "Access,Excel"


def test_vm_office_ignores_a_previous_runs_marker(guest: tuple[Path, dict[str, str]]) -> None:
    store, env = guest
    (store / "C__autowin-office.done").write_text("2020-01-01T00:00:00\r\nAccess=old")
    res = _run("vm-office.sh", "vm1", env={**env, "FAKE_OFFICE_FAIL": "1"})
    assert res.returncode == 1
    assert "install failed: download blocked" in res.stderr


def test_vm_office_refuses_a_corrupted_copy(guest: tuple[Path, dict[str, str]]) -> None:
    store, env = guest
    res = _run("vm-office.sh", "vm1", env={**env, "FAKE_CORRUPT_PUSH": "1"})
    assert res.returncode == 1
    assert "copying install-office.ps1 into the guest failed" in res.stderr
    assert "-File" not in (store / "_calls.log").read_text()  # never started


def test_vm_office_dry_run_runs_nothing(guest: tuple[Path, dict[str, str]]) -> None:
    store, env = guest
    res = _run("vm-office.sh", "--dry-run", "vm1", env=env)
    assert res.returncode == 0, res.stderr
    assert "+ utmctl file push" in res.stdout
    calls = (store / "_calls.log").read_text().splitlines()
    assert [c.split()[0] for c in calls] == ["status"]


def test_office_install_avoids_the_delivery_optimization_stall() -> None:
    # Regression: Office's main package sat at 0 MB in Delivery Optimization's LAN mode; the
    # policy is set (HTTP only) and the service restarted before the installer runs.
    ps1 = (ROOT / "examples/guest/install-office.ps1").read_text()
    policy = ps1.index("DODownloadMode")
    assert "-Value 0" in ps1[policy : policy + 200]
    assert policy < ps1.index("Restart-Service DoSvc") < ps1.index("'/configure'")


def test_messages_print_windows_paths_literally(guest: tuple[Path, dict[str, str]]) -> None:
    # Regression: zsh's print turned "C:\\autowin-office.log" into "C:" + BEL + "utowin-office.log".
    _, env = guest
    res = _run("vm-office.sh", "vm1", env={**env, "FAKE_OFFICE_FAIL": "1"})
    assert res.returncode == 1
    assert "C:\\autowin-office.log" in res.stderr and "\a" not in res.stderr
