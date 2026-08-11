"""Generate assets/textures/plane_grid.png — the detected-wall highlight.

Needed because neither platform draws a usable highlight on its own:

* Android — Sceneform's default PlaneRenderer only shades within
  MATERIAL_SPOTLIGHT_RADIUS (0.5 m) of the focus point, using a very faint dot
  grid. On a wall at 1-1.5 m that is close to invisible. The plugin raises the
  radius to 10 m *only* when a customPlaneTexturePath is supplied
  (AndroidARView.kt:560-589), so supplying one is what turns the highlight on.
* iOS — with no texture, makePlane leaves SCNPlane's default white material at
  0.3 opacity (ArModelBuilder.swift:16-31). Supplying one gives it a real
  textured material at full opacity.

Tileable 64x64: Sceneform repeats it about every 0.5 m. SceneKit stretches one
copy across the whole plane instead, so the design has to read both ways — hence
a border plus a centre cross rather than a fine grid.
"""

import utils.http_session
import utils.transport
import utils.session
import struct
import sys
import zlib

SIZE = 64
BORDER = 3
CROSS_HALF = 6
CROSS_ARM = 10

# Cyan reads clearly against paint, wood and most curtain fabric.
LINE = (0, 220, 255, 210)
FILL = (0, 180, 255, 46)
CLEAR = (0, 0, 0, 0)


def pixel(x: int, y: int):
    on_border = x < BORDER or y < BORDER or x >= SIZE - BORDER or y >= SIZE - BORDER
    if on_border:
        return LINE

    cx = cy = SIZE // 2
    dx, dy = abs(x - cx), abs(y - cy)
    if (dx <= 1 and dy <= CROSS_ARM) or (dy <= 1 and dx <= CROSS_ARM):
        return LINE
    if dx <= CROSS_HALF and dy <= CROSS_HALF:
        return FILL
    return FILL if (x + y) % 16 < 8 else CLEAR


def chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def main(path: str) -> None:
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)  # filter type 0 (None) for this scanline
        for x in range(SIZE):
            raw.extend(pixel(x, y))

    png = bytearray(b"\x89PNG\r\n\x1a\n")
    # 8-bit RGBA, no interlace
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    with open(path, "wb") as f:
        f.write(png)
    print(f"wrote {path}: {len(png)} bytes ({SIZE}x{SIZE} RGBA)")


if __name__ == "__main__":
    main(sys.argv[1])
