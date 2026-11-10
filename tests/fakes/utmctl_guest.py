#!/usr/bin/env python3
"""A fake `utmctl` with a fake guest file system (FAKE_GUEST dir), like the real one in that
`exec` and `file` print errors but still exit 0.

FAKE_SILENT=1      exec does nothing (no guest agent)
FAKE_OFFICE_FAIL=1 the Office install writes its failed marker
FAKE_CORRUPT_PUSH  pushed files are stored altered
"""

from __future__ import annotations

import base64
import os
import re
import sys
from pathlib import Path

store = Path(os.environ["FAKE_GUEST"])
log = store / "_calls.log"


def host(path: str) -> Path:
    return store / re.sub(r"[\\:]", "_", path)


def main(argv: list[str]) -> int:
    with log.open("a") as fh:
        fh.write(" ".join(argv) + "\n")
    args = [a for a in argv if a != "--hide"]
    if args[0] == "status":
        status_file = store / "_status"
        print(
            status_file.read_text()
            if status_file.exists()
            else os.environ.get("FAKE_STATUS", "started")
        )
        return 0
    if args[0] in ("start", "stop"):
        (store / "_status").write_text("started" if args[0] == "start" else "stopped")
        return 0
    if args[0] == "delete":
        (store / "_status").write_text("deleted")
        return 0
    if args[:2] == ["file", "push"]:
        data = sys.stdin.buffer.read()
        if os.environ.get("FAKE_CORRUPT_PUSH"):
            data += b"\n# altered"
        host(args[3]).write_bytes(data)
        return 0
    if args[:2] == ["file", "pull"]:
        p = host(args[3])
        if p.exists():
            sys.stdout.buffer.write(p.read_bytes())
        else:
            print(f"failed to open file '{args[3]}'", file=sys.stderr)
        return 0
    if args[0] == "exec":
        if os.environ.get("FAKE_SILENT"):
            print(
                "The QEMU guest agent is not running or not installed on the guest.",
                file=sys.stderr,
            )
            return 0
        cmd = args[args.index("--cmd") + 1 :]
        if cmd[:2] == ["cmd.exe", "/c"] and cmd[2].startswith("del "):
            for path in cmd[2].split()[1:]:
                if not path.startswith("/"):
                    host(path).unlink(missing_ok=True)
        elif "-EncodedCommand" in cmd:
            code = base64.b64decode(cmd[cmd.index("-EncodedCommand") + 1]).decode("utf-16-le")
            # the results the host pulls (with --user the wrapper copies them there)
            out = re.search(r"'(C:\\autowin-ps\\[^']+\.out)'", code)
            fin = re.search(r"'(C:\\autowin-ps\\[^']+\.done)'", code)
            assert out and fin, code
            failed = "throw" in code
            if "AUTOWIN_COUNT_LICENSES" in code:
                body = os.environ.get("FAKE_LICENSES", "1").encode() + b"\r\n"
            else:
                body = b"ERROR: thrown\r\n" if failed else b"guest says hi\r\n"
            host(out.group(1)).write_bytes(b"\xef\xbb\xbf" + body)
            host(fin.group(1)).write_text("1" if failed else "0")
        elif "-File" in cmd and cmd[cmd.index("-File") + 1].endswith("release-office.ps1"):
            if os.environ.get("FAKE_RELEASE_FAIL"):
                host(r"C:\autowin-license.failed").write_text("the account sign-out did not run")
            else:
                host(r"C:\autowin-license.released").write_text(
                    "2026-11-10T17:00:00.0000000-05:00\r\naccounts signed out: 1\r\nlicense files removed: 1"
                )
        elif "-File" in cmd and cmd[cmd.index("-File") + 1].endswith("install-office.ps1"):
            apps = cmd[cmd.index("-Apps") + 1]
            host(r"C:\autowin-office.args").write_text(apps)
            if os.environ.get("FAKE_OFFICE_FAIL"):
                host(r"C:\autowin-office.failed").write_text("download blocked")
            else:
                lines = ["2026-11-10T14:30:00.0000000-05:00"] + [
                    f"{a}=C:\\Program Files\\Microsoft Office\\root\\Office16\\{a.upper()}.EXE"
                    for a in apps.split(",")
                ]
                host(r"C:\autowin-office.done").write_text("\r\n".join(lines))
        return 0
    print(f"fake utmctl: unsupported: {argv}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
