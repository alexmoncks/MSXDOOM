#!/usr/bin/env python3
"""Shared constants and helpers of the MSX DOOM build tools (pure Python 3, no packages).

The map comes from js/game.js and the art from assets/msx (written by
tools/build_assets.ps1), so the browser prototype and the MSX cartridge share
one source for both.
"""
import os
import re
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
MSX = os.path.dirname(HERE)
ROOT = os.path.dirname(MSX)
OUT = os.path.join(MSX, "out")
ASSETS = os.path.join(ROOT, "assets", "msx")

# ---------------------------------------------------------------- the target
CELL = 256              # world units per map cell (1 unit = 1/4 texel of a wall)
EYE = 128               # eye height
WALL_H = 256
VIEW_W, VIEW_H = 256, 180
FOCAL = 128             # geo3d F: 90 degrees across 256 pixels
CX, CY = 128, 90
ZNEAR = 2               # geo3d ZNEAR (the Z80 clips the near walls itself, at ZCLIP)
ZCLIP = 16              # camera-space Z where the Z80 cuts the walls next to the player
ZSCALE = 32             # the Z80 keeps those Z values times 32
SPLIT_DIST = 3.2        # far faces closer than this (cells) are sent as two halves
TEXY = 512              # the texture area: VRAM rows 512..1023 (SCREEN 8 pages 2 and 3)
TSTRIDE = 64
LEVELS = 6              # light levels 0..5 = palette sets 1..6
FOV_HALF = 32           # half the horizontal field of view, in 1/256 of a turn
YAW_MARGIN = 24         # the loaded faces cover the build yaw +- this much turning
DRAW_DIST = 12          # view range in cells
VMAX_STATIC = 200       # vertices the near strips and the far faces may take (of geo3d's 255)
FMAX_STATIC = 130

DIRS = [(1, 0), (-1, 0), (0, 1), (0, -1)]       # face direction A -> B and step codes: +x -x +z -z

# light, as in js/game.js
AMBIENT, PLAYER_LIGHT, PLAYER_LIGHT_RANGE = 1.3, 3.2, 7
LAMP_POWER, LAMP_RANGE, TECH_POWER, TECH_RANGE = 3.6, 4.5, 1.5, 2.6

WALL_TEX = {"#": 0, "T": 1, "R": 2}             # steel, tech, rock
ENEMY_CH = {"f": 0, "z": 1}                     # fiend, zombie


def load_map():
    src = open(os.path.join(ROOT, "js", "game.js"), encoding="utf-8").read()
    m = re.search(r"var MAP = \[(.*?)\];", src, re.S)
    rows = re.findall(r"'([^']*)'", m.group(1))
    assert rows and all(len(r) == len(rows[0]) for r in rows), "MAP rows differ in width"
    return rows


def load_idx(name):
    return open(os.path.join(ASSETS, name + ".idx"), "rb").read()


def load_palette():
    """256 x (r, g, b), 5 bits each."""
    d = open(os.path.join(ASSETS, "palette.pal"), "rb").read()
    return [tuple(d[3 * i:3 * i + 3]) for i in range(256)]


def shade(rgb, t):
    """tools/build_assets.ps1 Shade(): r, g, b in 0..1, t = light 0..1."""
    r, g, b = rgb
    kr = 0.10 + 0.90 * t ** 1.15
    kg = 0.02 + 0.98 * t ** 1.75
    lum = 0.30 * r + 0.59 * g + 0.11 * b
    r = r * kr + lum * 0.16 * (1 - t) * t * 4
    return (min(1.0, r), g * kg, b * kg)


def to5(v):
    return max(0, min(31, int(round(v * 31))))


def write_png(path, w, h, rgb):
    """rgb: bytes, 3 per pixel."""
    raw = b"".join(b"\0" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def indexed_png(path, w, h, pix, pal, scale=1):
    """pix: one palette index per pixel; pal: 256 x (r, g, b) 5-bit."""
    lut = [bytes(((c << 3) | (c >> 2)) for c in e) for e in pal]
    out = bytearray()
    for y in range(h):
        row = b"".join(lut[pix[y * w + x]] * scale for x in range(w))
        out += row * scale
    write_png(path, w * scale, h * scale, bytes(out))


def s16(v):
    return v & 0xFFFF


def sin_q14(a):
    import math
    return int(round(math.sin(2 * math.pi * (a & 255) / 256) * 16384))
