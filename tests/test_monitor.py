"""vm-keys.sh, vm-screen.sh and ppm2png.py against a fake QEMU monitor socket."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import threading
from collections.abc import Iterator
from pathlib import Path

import pytest

from examples.tools.ppm2png import ppm_to_png

ROOT = Path(__file__).resolve().parent.parent
ZSH_DIR = ROOT / "examples" / "zsh"
ZSH = shutil.which("zsh")
PPM = b"P6\n# made by a test\n2 1\n255\n" + bytes([255, 0, 0, 0, 0, 255])


class FakeMonitor:
    """A unix socket that records HMP commands; `screendump F` writes a small PPM to F."""

    def __init__(self, group: Path, name: str) -> None:
        self.group = group
        self.lines: list[str] = []
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(group / f"{name}.mon"))
        self.sock.listen(4)
        self.sock.settimeout(0.2)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        while not self.stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except TimeoutError:
                continue
            conn.settimeout(1.0)
            buf = b""
            with conn:
                conn.sendall(b"QEMU monitor\r\n(qemu) ")
                while True:
                    try:
                        chunk = conn.recv(4096)
                    except TimeoutError:
                        break  # idle: the client has sent everything
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        cmd = line.decode().strip()
                        self.lines.append(cmd)
                        if cmd.startswith("screendump "):
                            (self.group / cmd.split()[1]).write_bytes(PPM)
                        conn.sendall(b"(qemu) ")


@pytest.fixture
def monitor() -> Iterator[tuple[FakeMonitor, dict[str, str]]]:
    # Short path: unix socket paths are limited to 104 bytes on macOS.
    group = Path(tempfile.mkdtemp(prefix="aw", dir="/tmp"))
    fake = FakeMonitor(group, "vm1")
    env = {**os.environ, "UTM_GROUP": str(group)}
    yield fake, env
    fake.stop.set()
    fake.thread.join()
    shutil.rmtree(group)


def _run(*args: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    assert ZSH is not None, "zsh is required for these tests"
    return subprocess.run([ZSH, "-f", *args], capture_output=True, text=True, env=env, timeout=60)


def test_keys_for_maps_text_to_sendkey() -> None:
    res = _run(
        "-c", r'source examples/zsh/monitor.zsh; keys_for "fs0:\efi\B a.x"', env=dict(os.environ)
    )
    assert res.returncode == 0, res.stderr
    assert res.stdout.split("\n")[:-1] == [
        "sendkey f",
        "sendkey s",
        "sendkey 0",
        "sendkey shift-semicolon",
        "sendkey backslash",
        "sendkey e",
        "sendkey f",
        "sendkey i",
        "sendkey backslash",
        "sendkey shift-b",
        "sendkey spc",
        "sendkey a",
        "sendkey dot",
        "sendkey x",
        "sendkey ret",
    ]


def test_keys_for_refuses_untypable_characters() -> None:
    res = _run("-c", 'source examples/zsh/monitor.zsh; keys_for "é"', env=dict(os.environ))
    assert res.returncode != 0
    assert "cannot type" in res.stderr


def test_vm_keys_types_text_then_enter(monitor: tuple[FakeMonitor, dict[str, str]]) -> None:
    fake, env = monitor
    res = _run(str(ZSH_DIR / "vm-keys.sh"), "vm1", "ver", env=env)
    assert res.returncode == 0, res.stderr
    assert fake.lines == ["sendkey v", "sendkey e", "sendkey r", "sendkey ret"]


def test_vm_keys_any_key_presses_space_twice_a_second(
    monitor: tuple[FakeMonitor, dict[str, str]],
) -> None:
    fake, env = monitor
    res = _run(str(ZSH_DIR / "vm-keys.sh"), "--any-key", "1", "vm1", env=env)
    assert res.returncode == 0, res.stderr
    assert fake.lines == ["sendkey spc", "sendkey spc"]


def test_vm_keys_fails_without_a_socket(monitor: tuple[FakeMonitor, dict[str, str]]) -> None:
    _, env = monitor
    res = _run(str(ZSH_DIR / "vm-keys.sh"), "other", "ver", env=env)
    assert res.returncode != 0
    assert "no QEMU monitor socket" in res.stderr


def test_vm_screen_writes_a_png(
    monitor: tuple[FakeMonitor, dict[str, str]], tmp_path: Path
) -> None:
    fake, env = monitor
    out = tmp_path / "shot.png"
    res = _run(str(ZSH_DIR / "vm-screen.sh"), "vm1", str(out), env=env)
    assert res.returncode == 0, res.stderr
    assert fake.lines == ["screendump vm1.screen.ppm"]
    assert out.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    assert not (Path(env["UTM_GROUP"]) / "vm1.screen.ppm").exists()  # cleaned up


def test_ppm_to_png_dimensions_and_errors() -> None:
    png, width, height = ppm_to_png(PPM)
    assert (width, height) == (2, 1) and png[12:16] == b"IHDR"
    with pytest.raises(ValueError, match="P6"):
        ppm_to_png(b"P3\n1 1\n255\n0 0 0\n")
    with pytest.raises(ValueError, match="truncated"):
        ppm_to_png(b"P6\n4 4\n255\n" + b"\x00" * 5)
