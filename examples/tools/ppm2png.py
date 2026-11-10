"""Convert a binary PPM (P6), as written by QEMU's screendump, to PNG. Standard library only.

Usage: python3 ppm2png.py SCREEN.ppm OUT.png   (prints WIDTH HEIGHT)
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path


def ppm_to_png(data: bytes) -> tuple[bytes, int, int]:
    fields: list[bytes] = []
    i = 0
    while len(fields) < 4:  # magic, width, height, maxval; comments allowed between them
        while data[i : i + 1].isspace():
            i += 1
        if data[i : i + 1] == b"#":
            while data[i : i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while j < len(data) and not data[j : j + 1].isspace():
            j += 1
        fields.append(data[i:j])
        i = j
    i += 1  # the single whitespace byte after maxval
    if fields[0] != b"P6" or fields[3] != b"255":
        raise ValueError("not an 8-bit binary PPM (P6)")
    width, height = int(fields[1]), int(fields[2])
    pixels = data[i : i + width * height * 3]
    if len(pixels) != width * height * 3:
        raise ValueError("PPM is truncated")
    stride = width * 3
    raw = b"".join(b"\x00" + pixels[y * stride : (y + 1) * stride] for y in range(height))

    def chunk(kind: bytes, body: bytes) -> bytes:
        crc = zlib.crc32(kind + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 6))
    return png + chunk(b"IEND", b""), width, height


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    png, width, height = ppm_to_png(Path(argv[1]).read_bytes())
    Path(argv[2]).write_bytes(png)
    print(width, height)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
