"""Exercise the Azure browser handoff without an Azure session or Windows VM."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "examples" / "zsh" / "vm-azure-login.sh"
TENANT = "11111111-1111-1111-1111-111111111111"
PRINCIPAL = "22222222-2222-2222-2222-222222222222"


@pytest.fixture
def tools(tmp_path: Path) -> tuple[dict[str, str], Path]:
    log = tmp_path / "guest.log"
    az = tmp_path / "az"
    az.write_text(
        f'#!/bin/sh\ncase "$1" in account) echo {TENANT} ;; ad) echo {PRINCIPAL} ;; esac\n'
    )
    guest = tmp_path / "guest"
    guest.write_text(
        f"#!{sys.executable}\n"
        """
import base64
import os
import re
import sys
from pathlib import Path

log = Path(os.environ["GUEST_TRACE"])
code = sys.argv[-1]
if "Start-Process 'powershell.exe'" in code:
    encoded = re.search(r"-EncodedCommand ([A-Za-z0-9+/=]+)", code)[1]
    log.write_text(base64.b64decode(encoded).decode("utf-16-le"))
    print("Browser opened.")
else:
    assert "22222222-2222-2222-2222-222222222222" in code
    state = os.environ["GUEST_AZURE_STATE"]
    print("AZURE_SIGN_IN_READY" if state == "pending" and log.exists() else
          {"pending": "AZURE_SIGN_IN_PENDING", "ready": "AZURE_SIGN_IN_READY",
           "wrong": "AZURE_SIGN_IN_WRONG_USER"}[state])
"""
    )
    for program in (az, guest):
        program.chmod(0o755)
    return {
        **os.environ,
        "PATH": f"{tmp_path}:{os.environ['PATH']}",
        "AUTOWIN_VM_PS": str(guest),
        "GUEST_TRACE": str(log),
    }, log


def invoke(env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    zsh = shutil.which("zsh")
    assert zsh is not None
    return subprocess.run(
        [zsh, "-f", str(SCRIPT), *args], capture_output=True, text=True, env=env, timeout=10
    )


def test_dry_run_skips_host_and_guest_login(tools: tuple[dict[str, str], Path]) -> None:
    env, log = tools
    result = invoke({**env, "AUTOWIN_VM_PS": "/nonexistent"}, "--dry-run", "signing-vm", "builder")
    assert result.returncode == 0, result.stderr
    assert "Edge" in result.stdout
    assert not log.exists()


def test_pending_login_opens_edge_and_returns_only_when_verified(
    tools: tuple[dict[str, str], Path],
) -> None:
    env, log = tools
    result = invoke({**env, "GUEST_AZURE_STATE": "pending"}, "signing-vm", "builder")
    assert result.returncode == 0, result.stderr
    assert "verified" in result.stdout
    browser = log.read_text()
    assert "msedge.exe" in browser and "$env:BROWSER" in browser
    assert "--use-device-code" not in browser
    assert "--tenant" in browser and TENANT in browser
    assert PRINCIPAL not in result.stdout


@pytest.mark.parametrize(("state", "exit_code"), [("ready", 0), ("wrong", 1)])
def test_existing_guest_identity_is_checked_without_opening_a_browser(
    tools: tuple[dict[str, str], Path], state: str, exit_code: int
) -> None:
    env, log = tools
    result = invoke({**env, "GUEST_AZURE_STATE": state}, "signing-vm", "builder")
    assert result.returncode == exit_code, result.stderr
    assert not log.exists()
    assert (
        "different Azure identity" in result.stderr
        if state == "wrong"
        else "verified" in result.stdout
    )
