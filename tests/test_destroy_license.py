"""vm-destroy.sh releases a VM's Office license before deleting it (fake guest)."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FAKE = ROOT / "tests" / "fakes" / "utmctl_guest.py"
ZSH = shutil.which("zsh")


@pytest.fixture
def vm(tmp_path: Path) -> tuple[Path, dict[str, str]]:
    store = tmp_path / "guest"
    store.mkdir()
    (store / "C__autowin-setup.done").write_text("2026-11-10T14:00:00.0-05:00")
    env = {
        **os.environ,
        "UTMCTL": str(FAKE),
        "FAKE_GUEST": str(store),
        "AUTOWIN_STATE": str(tmp_path / "state"),
    }
    return store, env


def _destroy(*args: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    assert ZSH is not None, "zsh is required for these tests"
    return subprocess.run(
        [ZSH, "-f", str(ROOT / "examples/zsh/vm-destroy.sh"), *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
    )


def _calls(store: Path) -> list[str]:
    return (store / "_calls.log").read_text().splitlines()


def _index(calls: list[str], needle: str) -> int:
    return next(i for i, c in enumerate(calls) if needle in c)


def test_releases_the_license_then_deletes(vm: tuple[Path, dict[str, str]]) -> None:
    store, env = vm
    res = _destroy("vm1", env=env)
    assert res.returncode == 0, res.stderr
    assert "released the Office license in vm1" in res.stdout
    assert "license files removed: 1" in res.stdout
    assert "device list" in res.stdout
    calls = _calls(store)
    assert _index(calls, "release-office.ps1 -User tester") < _index(calls, "delete vm1")
    pushed = (store / "C__autowin-office_release-office.ps1").read_bytes()
    assert pushed == (ROOT / "examples/guest/release-office.ps1").read_bytes()


def test_without_a_license_nothing_is_released(vm: tuple[Path, dict[str, str]]) -> None:
    store, env = vm
    res = _destroy("vm1", env={**env, "FAKE_LICENSES": "0"})
    assert res.returncode == 0, res.stderr
    assert "no Office license in vm1" in res.stdout
    assert not any("release-office.ps1 -User" in c for c in _calls(store))
    assert any("delete vm1" in c for c in _calls(store))


def test_a_failed_release_keeps_the_vm(vm: tuple[Path, dict[str, str]]) -> None:
    store, env = vm
    res = _destroy("vm1", env={**env, "FAKE_RELEASE_FAIL": "1"})
    assert res.returncode == 1
    assert "releasing the Office license failed" in res.stderr and "nothing deleted" in res.stderr
    assert not any("delete vm1" in c for c in _calls(store))


def test_a_clone_keeps_the_license_by_default(vm: tuple[Path, dict[str, str]]) -> None:
    store, env = vm
    state = Path(env["AUTOWIN_STATE"]) / "vm1"
    state.mkdir(parents=True)
    (state / "clone-of").write_text("base\n")
    res = _destroy("vm1", env=env)
    assert res.returncode == 0, res.stderr
    assert "keeping the Office license: vm1 is a clone of base" in res.stdout
    assert not any("release-office.ps1" in c for c in _calls(store))
    assert any("delete vm1" in c for c in _calls(store))
    assert not state.exists()


def test_release_license_overrides_for_a_clone(vm: tuple[Path, dict[str, str]]) -> None:
    store, env = vm
    state = Path(env["AUTOWIN_STATE"]) / "vm1"
    state.mkdir(parents=True)
    (state / "clone-of").write_text("base\n")
    res = _destroy("--release-license", "vm1", env=env)
    assert res.returncode == 0, res.stderr
    assert "released the Office license in vm1" in res.stdout
    calls = _calls(store)
    assert _index(calls, "release-office.ps1 -User") < _index(calls, "delete vm1")


def test_a_stopped_vm_is_started_for_the_release(vm: tuple[Path, dict[str, str]]) -> None:
    store, env = vm
    res = _destroy("vm1", env={**env, "FAKE_STATUS": "stopped"})
    assert res.returncode == 0, res.stderr
    assert "starting vm1 to release its Office license" in res.stdout
    calls = _calls(store)
    assert _index(calls, "start --hide vm1") < _index(calls, "release-office.ps1 -User")


def test_keep_license_skips_the_release(vm: tuple[Path, dict[str, str]]) -> None:
    store, env = vm
    res = _destroy("--keep-license", "vm1", env=env)
    assert res.returncode == 0, res.stderr
    assert not any("release-office.ps1" in c for c in _calls(store))


def test_a_vm_with_clones_keeps_the_license_by_default(vm: tuple[Path, dict[str, str]]) -> None:
    # Releasing the source's license would sign its clones out too (shared device identity).
    store, env = vm
    clone_state = Path(env["AUTOWIN_STATE"]) / "vm1-run"
    clone_state.mkdir(parents=True)
    (clone_state / "clone-of").write_text("vm1\n")
    res = _destroy("vm1", env=env)
    assert res.returncode == 0, res.stderr
    assert "keeping the Office license: vm1 has clones (vm1-run)" in res.stdout
    assert not any("release-office.ps1" in c for c in _calls(store))


def test_a_stale_failure_marker_is_not_taken_as_this_runs_result(
    vm: tuple[Path, dict[str, str]],
) -> None:
    # Regression: utmctl exec returns at once, and the marker of an earlier failed attempt was
    # read before the new run removed it: a release that succeeded was reported as failed.
    store, env = vm
    (store / "C__autowin-license.failed").write_text("the account sign-out did not run")
    res = _destroy("vm1", env=env)
    assert res.returncode == 0, res.stderr
    assert "released the Office license in vm1" in res.stdout
    calls = _calls(store)
    assert _index(
        calls, "del /f /q C:\\autowin-license.released C:\\autowin-license.failed"
    ) < _index(calls, "release-office.ps1 -User")


def test_release_waits_for_the_users_desktop() -> None:
    # Regression: right after start the guest agent answered before the user was logged in, and
    # the sign-out task could not run in a session that did not exist yet.
    ps1 = (ROOT / "examples/guest/release-office.ps1").read_text()
    wait = ps1.index("explorer")
    assert wait < ps1.index("Register-ScheduledTask")
    assert "-lt 120" in ps1  # result wait, seconds
