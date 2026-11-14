#!/usr/bin/env python3
"""Print a QEMU screendump (PPM) as a base64 PNG between markers.

    python3 iso/screenshot.py screen.ppm

CI logs are the one output always at hand: the image is decoded from the log
with `sed -n '/^GRAVEYARD-SCREEN-BEGIN/,/^GRAVEYARD-SCREEN-END/p' | sed '1d;$d' |
base64 -d > screen.png`. Screens wider than 1024 pixels are halved.
"""
import base64
import struct
import sys
import zlib

data = open(sys.argv[1], "rb").read()
parts = data.split(maxsplit=4)
assert parts[0] == b"P6", "not a binary PPM"
w, h, pixels = int(parts[1]), int(parts[2]), parts[4]
step = 2 if w > 1024 else 1  # text modes (720x400) stay readable at full size
rows = []
for y in range(0, h, step):
    row = bytearray(b"\0")
    for x in range(0, w, step):
        i = (y * w + x) * 3
        row += pixels[i:i + 3]
    rows.append(bytes(row))
w2, h2 = (w + step - 1) // step, (h + step - 1) // step


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w2, h2, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))
print("GRAVEYARD-SCREEN-BEGIN")
text = base64.b64encode(png).decode()
for i in range(0, len(text), 76):
    print(text[i:i + 76])
print("GRAVEYARD-SCREEN-END")
