"""vm-clone.sh against a fake utmctl, a fake PlistBuddy (a JSON file) and a fake osascript."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
ZSH = shutil.which("zsh")


@pytest.fixture
def world(tmp_path: Path) -> tuple[Path, dict[str, str]]:
    docs, bindir, log = tmp_path / "docs", tmp_path / "bin", tmp_path / "calls.log"
    docs.mkdir()
    bindir.mkdir()
    base = {
        "QEMU": {"AdditionalArguments": ["-monitor", "unix:base.mon,server=on,wait=off"]},
        "Network": [{"MacAddress": "52:FF:DA:29:5C:C6"}],
    }
    (docs / "base.utm").mkdir()
    (docs / "base.utm" / "config.json").write_text(json.dumps(base))
    utmctl = f"""#!/bin/sh
echo "utmctl $*" >> {log}
case "$1" in
  status) [ "$2" = base ] && echo "${{BASE_STATUS:-stopped}}" && exit 0
          [ -d "{docs}/$2.utm" ] && echo stopped && exit 0; exit 1 ;;
  clone) cp -R "{docs}/$2.utm" "{docs}/$4.utm"; exit 0 ;;
esac
exit 0
"""
    # PlistBuddy -c "Set :A:B:0 value" ... FILE   (works on config.json next to config.plist)
    plistbuddy = f"""#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
path = args[-1].replace("config.plist", "config.json")
cfg = json.load(open(path))
with open("{log}", "a") as fh: fh.write("plistbuddy " + " ".join(args) + "\\n")
for i, a in enumerate(args[:-1]):
    if a != "-c": continue
    cmd = args[i + 1]
    verb, rest = cmd.split(" ", 1)
    key, _, value = rest.partition(" ")
    parts = key.strip(":").split(":")
    node = cfg
    for p in parts[:-1]: node = node[int(p)] if p.isdigit() else node[p]
    last = int(parts[-1]) if parts[-1].isdigit() else parts[-1]
    if verb == "Set": node[last] = value
    elif verb == "Print": print(node[last])
json.dump(cfg, open(path, "w"))
"""
    osascript = f'#!/bin/sh\necho "osascript $*" >> {log}\n'
    for name, body in (("utmctl", utmctl), ("PlistBuddy", plistbuddy), ("osascript", osascript)):
        (bindir / name).write_text(body)
        (bindir / name).chmod(0o755)
    env = {
        **os.environ,
        "UTMCTL": str(bindir / "utmctl"),
        "PLISTBUDDY": str(bindir / "PlistBuddy"),
        "UTM_DOCS": str(docs),
        "AUTOWIN_STATE": str(tmp_path / "state"),
        "PATH": f"{bindir}:{os.environ['PATH']}",
    }
    return docs, env


def _run(*args: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    assert ZSH is not None, "zsh is required for these tests"
    return subprocess.run(
        [ZSH, "-f", str(ROOT / "examples/zsh/vm-clone.sh"), *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )


def test_clone_gets_its_own_monitor_socket_and_mac(world: tuple[Path, dict[str, str]]) -> None:
    docs, env = world
    res = _run("base", "run1", env=env)
    assert res.returncode == 0, res.stderr
    cfg = json.loads((docs / "run1.utm" / "config.json").read_text())
    assert cfg["QEMU"]["AdditionalArguments"][1] == "unix:run1.mon,server=on,wait=off"
    mac = cfg["Network"][0]["MacAddress"]
    assert re.fullmatch(r"([0-9A-F]{2}:){5}[0-9A-F]{2}", mac) and mac != "52:FF:DA:29:5C:C6"
    assert int(mac[:2], 16) & 0b11 == 0b10  # locally administered, unicast
    base = json.loads((docs / "base.utm" / "config.json").read_text())
    assert base["Network"][0]["MacAddress"] == "52:FF:DA:29:5C:C6"  # the source is untouched
    assert "reload configuration" in (docs.parent / "calls.log").read_text()
    assert (docs.parent / "state" / "run1" / "clone-of").read_text().strip() == "base"


def test_clone_refuses_a_running_source(world: tuple[Path, dict[str, str]]) -> None:
    docs, env = world
    res = _run("base", "run1", env={**env, "BASE_STATUS": "started"})
    assert res.returncode != 0
    assert "stop base first" in res.stderr
    assert not (docs / "run1.utm").exists()


def test_clone_refuses_an_existing_target(world: tuple[Path, dict[str, str]]) -> None:
    docs, env = world
    (docs / "run1.utm").mkdir()
    res = _run("base", "run1", env=env)
    assert res.returncode != 0
    assert "already exists" in res.stderr


def test_clone_dry_run_changes_nothing(world: tuple[Path, dict[str, str]]) -> None:
    docs, env = world
    res = _run("--dry-run", "base", "run1", env=env)
    assert res.returncode == 0, res.stderr
    assert "+ " in res.stdout
    assert not (docs / "run1.utm").exists()
