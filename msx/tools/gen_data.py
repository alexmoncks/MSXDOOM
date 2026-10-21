#!/usr/bin/env python3
"""gen_data.py - builds everything the MSX DOOM cartridge reads from ROM.

  out/tex.bin        256 x 512 bytes: the texture area (VRAM rows 512..1023 of SCREEN 8)
  out/palettes.bin   4 palettes of 256 x (R, G, B) 5-bit: normal, hurt, pickup, muzzle flash
  out/vis.bin        cell-to-cell visibility, one bit row per free cell
  out/nextstep.bin   2 bits per (player cell, enemy cell): the enemy's next step
  out/pvs_N.bin      per-cell face lists, packed in 16 KB banks; out/pvsptr.bin points at them
  out/inc/const.asm, out/inc/tables.asm   constants and the small tables of bank 0
  out/world.json     the same data for tools/sim.py
  out/preview_*.png  what was built

What the Z80 does NOT do, and so is done here: visibility. For every free cell
the tool casts rays from a grid of points inside it and keeps the wall faces
they reach. The faces of the 3 x 3 cells around the player ("near") may cross
the near plane, so the Z80 clips them every frame; the others ("far") are sent
to geo3d once per cell and per turn of the head and are only filtered by their
bearing. The light level of each face as seen from each cell is baked in too.
"""
import hashlib
import json
import math
import os
import sys
from collections import deque

from common import *

MAP = load_map()
MAP_W, MAP_H = len(MAP[0]), len(MAP)


def is_wall(x, z):
    return x < 0 or z < 0 or x >= MAP_W or z >= MAP_H or MAP[z][x] in WALL_TEX


def wall_tex(x, z):
    if x < 0 or z < 0 or x >= MAP_W or z >= MAP_H:
        return 0
    return WALL_TEX[MAP[z][x]]


FREE = [(x, z) for z in range(MAP_H) for x in range(MAP_W) if not is_wall(x, z)]
FREE_IDX = {c: i for i, c in enumerate(FREE)}
NFREE = len(FREE)

# ---------------------------------------------------------------- faces
# side: 0 N (wall at z-1), 1 S, 2 E, 3 W. A -> B runs left to right as seen from the cell.
SIDE_STEP = [(0, -1), (0, 1), (1, 0), (-1, 0)]


def face_geom(cx, cz, side):
    """-> (ax, az, dir): corner A and the direction code of A -> B."""
    if side == 0:
        return cx, cz, 0
    if side == 1:
        return cx + 1, cz + 1, 1
    if side == 2:
        return cx + 1, cz, 2
    return cx, cz + 1, 3


def face_center(cx, cz, side):
    ax, az, d = face_geom(cx, cz, side)
    return ax + DIRS[d][0] * 0.5, az + DIRS[d][1] * 0.5


# ---------------------------------------------------------------- light (js/game.js)
LIGHTS = []
for z in range(MAP_H):
    for x in range(MAP_W):
        ch = MAP[z][x]
        if ch == "T":
            LIGHTS.append((x + 0.5, z + 0.5, TECH_POWER, TECH_RANGE, False))
        elif ch == "L":
            LIGHTS.append((x + 0.5, z + 0.5, LAMP_POWER, LAMP_RANGE, True))


def cast(ox, oz, dx, dz, maxd):
    """DDA. -> (distance, cells crossed, face hit or None)."""
    cx, cz = int(ox), int(oz)
    sx = 1 if dx > 0 else -1
    sz = 1 if dz > 0 else -1
    tdx = abs(1 / dx) if dx else 1e30
    tdz = abs(1 / dz) if dz else 1e30
    tmx = ((cx + 1 - ox) if dx > 0 else (ox - cx)) * tdx if dx else 1e30
    tmz = ((cz + 1 - oz) if dz > 0 else (oz - cz)) * tdz if dz else 1e30
    cells = []
    while True:
        cells.append((cx, cz))
        if tmx < tmz:
            t = tmx
            tmx += tdx
            if t >= maxd:
                return maxd, cells, None
            if is_wall(cx + sx, cz):
                return t, cells, (cx, cz, 2 if sx > 0 else 3)
            cx += sx
        else:
            t = tmz
            tmz += tdz
            if t >= maxd:
                return maxd, cells, None
            if is_wall(cx, cz + sz):
                return t, cells, (cx, cz, 1 if sz > 0 else 0)
            cz += sz


def line_of_sight(ax, az, bx, bz):
    dx, dz = bx - ax, bz - az
    d = math.hypot(dx, dz)
    if d < 1e-6:
        return True
    return cast(ax, az, dx / d, dz / d, d)[0] >= d


def face_static_light(cx, cz, side):
    """bonus + the lamps' share on the face of cell (cx, cz), as buildWorld() does."""
    qx, qz = face_center(cx, cz, side)
    tex = wall_tex(cx + SIDE_STEP[side][0], cz + SIDE_STEP[side][1])
    st = (-0.6 if side >= 2 else 0.0) + (1.2 if tex == 1 else 0.0)
    for lx, lz, power, rng, lamp in LIGHTS:
        d = math.hypot(lx - qx, lz - qz)
        if d >= rng:
            continue
        if lamp and not line_of_sight(lx, lz, cx + 0.5, cz + 0.5):
            continue
        k = 1 - d / rng
        st += power * k * k
    return st


def light_level(static, dist):
    lv = AMBIENT + static + PLAYER_LIGHT * max(0.0, 1 - dist / PLAYER_LIGHT_RANGE)
    if dist > DRAW_DIST - 2.5:
        lv -= (dist - (DRAW_DIST - 2.5)) * 2.4
    lv = max(0, min(6, int(math.floor(lv + 0.5))))
    return max(lv, 1) - 1                       # 0..5: palette sets 1..6


# ---------------------------------------------------------------- visibility
SAMPLES = 5                                     # points per axis inside a cell
RAYS = 900


def compute_pvs():
    key = hashlib.sha1(("\n".join(MAP) + f"|{SAMPLES}|{RAYS}|{DRAW_DIST}").encode()).hexdigest()
    cache = os.path.join(OUT, "pvs_cache.json")
    if os.path.exists(cache):
        d = json.load(open(cache))
        if d.get("key") == key:
            return ([set(tuple(f) for f in c) for c in d["faces"]],
                    [set(tuple(f) for f in c) for c in d["cells"]])
    dirs = [(math.sin(2 * math.pi * (i + 0.5) / RAYS), -math.cos(2 * math.pi * (i + 0.5) / RAYS))
            for i in range(RAYS)]
    faces, cells = [], []
    for n, (cx, cz) in enumerate(FREE):
        fs, cs = set(), {(cx, cz)}
        for j in range(SAMPLES):
            for i in range(SAMPLES):
                ox = cx + 0.03 + 0.94 * i / (SAMPLES - 1)
                oz = cz + 0.03 + 0.94 * j / (SAMPLES - 1)
                for dx, dz in dirs:
                    _, cl, hit = cast(ox, oz, dx, dz, DRAW_DIST)
                    cs.update(cl)
                    if hit:
                        fs.add(hit)
        faces.append(fs)
        cells.append(cs)
        if n % 40 == 0:
            print(f"  visibility {n}/{NFREE}", file=sys.stderr)
    json.dump({"key": key, "faces": [sorted(f) for f in faces], "cells": [sorted(c) for c in cells]},
              open(cache, "w"))
    return faces, cells


def bearing(dx, dz):
    """Yaw units (1/256 turn) of the direction (dx, dz); yaw 0 looks north (-z), 64 east."""
    return math.atan2(dx, -dz) * 256 / (2 * math.pi)


def build_pvs_lists(faces):
    """-> per free cell: (near entries, far entries) and statistics."""
    static_cache = {}
    lists = []
    for n, (cx, cz) in enumerate(FREE):
        near, far = [], []
        for (fx, fz, side) in faces[n]:
            if (fx, fz, side) not in static_cache:
                static_cache[(fx, fz, side)] = face_static_light(fx, fz, side)
            ax, az, d = face_geom(fx, fz, side)
            tex = wall_tex(fx + SIDE_STEP[side][0], fz + SIDE_STEP[side][1])
            qx, qz = face_center(fx, fz, side)
            dist = math.hypot(qx - (cx + 0.5), qz - (cz + 0.5))
            lvl = light_level(static_cache[(fx, fz, side)], dist)
            if abs(fx - cx) <= 1 and abs(fz - cz) <= 1:
                i, j = ax - (cx - 1), az - (cz - 1)
                assert 0 <= i <= 3 and 0 <= j <= 3
                near.append((dist, bytes([i | (j << 2) | (d << 4), tex | (lvl << 4)])))
            else:
                bx, bz = ax + DIRS[d][0], az + DIRS[d][1]
                ref = bearing(qx - (cx + 0.5), qz - (cz + 0.5))
                lo, hi = 0.0, 0.0
                for px in (cx, cx + 1):
                    for pz in (cz, cz + 1):
                        for (ex, ez) in ((ax, az), (bx, bz)):
                            dlt = (bearing(ex - px, ez - pz) - ref + 128) % 256 - 128
                            lo, hi = min(lo, dlt), max(hi, dlt)
                amin = math.floor(ref + lo)
                amax = math.ceil(ref + hi)
                a0 = (amin - FOV_HALF - YAW_MARGIN) % 256
                lim = min(255, (amax - amin) + 2 * (FOV_HALF + YAW_MARGIN))
                split = 0x80 if dist < SPLIT_DIST else 0     # two halves: less affine error
                far.append((dist, bytes([ax, az, d | (tex << 2) | (lvl << 4) | split, a0, lim])))
        near.sort()
        far.sort()
        lists.append(([e for _, e in near], [e for _, e in far]))
    return lists


def pvs_stats(lists):
    worst_f = worst_v = worst_n = 0
    total_f = 0
    over = 0
    for near, far in lists:
        worst_n = max(worst_n, len(near))
        # the near walls: four strips each, their corners shared among them
        ncorn = set()
        for e in near:
            i, j, d = e[0] & 3, (e[0] >> 2) & 3, e[0] >> 4
            ncorn |= {(i, j), (i + DIRS[d][0], j + DIRS[d][1])}
        near_v, near_f = 2 * len(ncorn) + 6 * len(near), 4 * len(near)
        for yaw in range(0, 256, 4):
            corners, nf, nv = set(), near_f, near_v
            for e in far:
                if (yaw - e[3]) % 256 <= e[4]:
                    d = e[2] & 3
                    c2 = {(e[0], e[1]), (e[0] + DIRS[d][0], e[1] + DIRS[d][1])}
                    if nv > VMAX_STATIC - 6 or nf > FMAX_STATIC - 2:
                        over += 1
                        break
                    nv += 2 * len(c2 - corners) + (2 if e[2] & 0x80 else 0)
                    corners |= c2
                    nf += 2 if e[2] & 0x80 else 1
            worst_f, worst_v = max(worst_f, nf), max(worst_v, nv)
            total_f += nf
    return dict(near_max=worst_n, static_faces_max=worst_f, static_verts_max=worst_v,
                static_faces_avg=round(total_f / (len(lists) * 64), 1), truncated_views=over)


# ---------------------------------------------------------------- enemies' paths
def build_nextstep():
    """2 bits per (player cell, enemy cell): the direction code of the enemy's next step."""
    rowlen = (NFREE + 3) // 4
    out = bytearray(NFREE * rowlen)
    for p, (px, pz) in enumerate(FREE):
        dist = {(px, pz): 0}
        q = deque([(px, pz)])
        while q:
            c = q.popleft()
            for dx, dz in DIRS:
                nb = (c[0] + dx, c[1] + dz)
                if nb in FREE_IDX and nb not in dist:
                    dist[nb] = dist[c] + 1
                    q.append(nb)
        for e, (ex, ez) in enumerate(FREE):
            best, code = dist.get((ex, ez), 9999), 0
            for k, (dx, dz) in enumerate(DIRS):
                nb = (ex + dx, ez + dz)
                if nb in dist and dist[nb] < best:
                    best, code = dist[nb], k
            out[p * rowlen + (e >> 2)] |= code << (2 * (e & 3))
    return bytes(out), rowlen


def build_vis(cells):
    rowlen = (NFREE + 7) // 8
    out = bytearray(NFREE * rowlen)
    for p in range(NFREE):
        for c in cells[p]:
            e = FREE_IDX[c]
            out[p * rowlen + (e >> 3)] |= 1 << (e & 7)
    return bytes(out), rowlen


# ---------------------------------------------------------------- textures
FRAMES = []        # billboard frames: name, u0, sy, w, h, half width, y0, y1 (world units)
FRAME_ID = {}


def build_texture():
    tex = bytearray(256 * 512)

    def blit(name, w, h, x0, y0, pset, transparent):
        idx = load_idx(name)
        for y in range(h):
            for x in range(w):
                p = idx[y * w + x]
                tex[(y0 + y) * 256 + x0 + x] = 0 if (transparent and p == 0) else p + 16 * pset

    for lvl in range(LEVELS):
        for n, name in enumerate(("wall_steel", "wall_tech", "wall_rock")):
            blit(name, 64, 64, 64 * n, 64 * lvl, lvl + 1, False)

    def frame(name, w, h, x0, y0, pset, halfw, wy0, wy1):
        blit(name, w, h, x0, y0, pset, True)
        FRAME_ID[name] = len(FRAMES)
        FRAMES.append(dict(name=name, u0=x0, sy=y0, w=w, h=h, halfw=halfw, y0=wy0, y1=wy1))

    for k, st in enumerate(("walk1", "walk2", "attack", "pain", "dying")):
        frame("fiend_" + st, 48, 64, 48 * k, 384, 7, 96, 0, 256)
    frame("fiend_dead", 48, 64, 192, 128, 7, 96, 0, 256)
    for k, st in enumerate(("walk1", "walk2", "attack", "pain", "dying")):
        frame("zombie_" + st, 48, 64, 48 * k, 448, 9, 96, 0, 256)
    frame("zombie_dead", 48, 64, 192, 192, 9, 96, 0, 256)
    frame("medkit", 32, 32, 192, 256, 12, 51, 0, 102)
    frame("muzzle_flash", 32, 32, 224, 256, 12, 28, 72, 128)
    blit("pistol", 64, 128, 192, 0, 11, True)
    # crosshair 9 x 9 at (240, 384): HUD white arms, red centre
    for k in (0, 1, 2, 6, 7, 8):
        tex[(384 + 4) * 256 + 240 + k] = 6
        tex[(384 + k) * 256 + 240 + 4] = 6
    tex[(384 + 4) * 256 + 240 + 4] = 3
    return bytes(tex)


# ---------------------------------------------------------------- sound effects (PSG)
def sfx_frames(n, tone=None, vol=(12, 0), noise=None, nvol=None):
    """n ticks of 1/60 s. tone: (f0, f1) Hz swept exponentially; noise: (p0, p1) noise periods.
    Each tick: flags | volume, tone period lo, hi, noise period (flags: 80h noise on, 40h tone off)."""
    out = bytearray()
    for i in range(n):
        k = i / max(1, n - 1)
        v = int(round(vol[0] + (vol[1] - vol[0]) * k))
        b0, per, npd = v & 15, 0, 0
        if tone:
            f = tone[0] * (tone[1] / tone[0]) ** k
            per = max(1, min(4095, int(round(111860.8 / f))))
        else:
            b0 |= 0x40
        if noise and (nvol is None or i < nvol):
            b0 |= 0x80
            npd = int(round(noise[0] + (noise[1] - noise[0]) * k)) & 31
        out += bytes([b0, per & 255, per >> 8, npd])
    return bytes(out)


SFX = [  # name, voice, frames
    ("shot", 0, sfx_frames(13, tone=(170, 42), vol=(15, 2), noise=(3, 22))),
    ("pain", 1, sfx_frames(7, tone=(260, 120), vol=(11, 3))),
    ("death", 1, sfx_frames(30, tone=(190, 35), vol=(13, 1), noise=(8, 28), nvol=20)),
    ("growl_f", 1, sfx_frames(21, tone=(90, 54), vol=(11, 2))),
    ("growl_z", 1, sfx_frames(21, tone=(62, 37), vol=(11, 2))),
    ("hurt", 1, sfx_frames(12, tone=(110, 70), vol=(13, 3), noise=(10, 20), nvol=7)),
    ("pickup", 1, sfx_frames(4, tone=(660, 660), vol=(12, 12)) + sfx_frames(4, tone=(880, 880), vol=(12, 12)) +
     sfx_frames(7, tone=(1320, 1320), vol=(12, 4))),
]


def ny_of(level):
    """The normal's Y that makes geo3d pick `level` under the light (0, 1, 0)."""
    return 0 if level == 0 else level * 2341 + 100


# ---------------------------------------------------------------- palettes
# floor / ceiling rows from the horizon: the edges of the fills. BANDS=... (comma
# separated) tries another set, for example BANDS=0,90 for one flat colour each.
BANDS = [0, 3, 7, 12, 19, 29, 43, 63, 90]
if os.environ.get("BANDS"):
    BANDS = [int(v) for v in os.environ["BANDS"].split(",")]
NB = len(BANDS) - 1
assert BANDS[0] == 0 and BANDS[-1] == VIEW_H // 2 and NB <= 15

HUD_COLOURS = {1: (2, 1, 1), 2: (10, 8, 8), 3: (31, 6, 5), 4: (31, 21, 3), 5: (19, 19, 19),
               6: (31, 31, 31), 7: (9, 1, 1), 8: (6, 25, 8), 9: (5, 4, 4)}


def build_palettes():
    pal = load_palette()
    base = list(pal)
    for i in range(16):
        base[i] = (0, 0, 0)
    for i, c in HUD_COLOURS.items():
        base[i] = c
    world = [tuple(v / 31 for v in pal[6 * 16 + i]) for i in range(16)]

    def mean(name):
        idx = load_idx(name)
        return tuple(sum(world[p][k] for p in idx) / len(idx) for k in range(3))

    for pset, name, bonus in ((14, "ceil", -0.4), (15, "floor", 0.0)):
        avg = mean(name)
        for k in range(NB):
            r = (BANDS[k] + BANDS[k + 1]) / 2
            d = EYE * FOCAL / max(r, 0.5) / CELL
            lv = AMBIENT + 1.5 + bonus + PLAYER_LIGHT * max(0.0, 1 - d / PLAYER_LIGHT_RANGE)
            if d > DRAW_DIST - 2.5:
                lv -= (d - (DRAW_DIST - 2.5)) * 2.4
            t = max(0.0, min(6.0, lv)) / 6
            base[pset * 16 + 1 + k] = tuple(to5(min(1.0, v * 1.25)) for v in shade(avg, t))
        base[pset * 16] = (0, 0, 0)

    tinted = lambda e: 16 <= e < 13 * 16 or e >= 14 * 16

    def mix(c, to, k):
        return tuple(int(round(c[i] + (to[i] - c[i]) * k)) for i in range(3))

    hurt = [mix(c, (31, 0, 0), 0.38) if tinted(e) else c for e, c in enumerate(base)]
    pick = [mix(c, (11, 31, 11), 0.30) if tinted(e) else c for e, c in enumerate(base)]
    flash = list(base)
    for lvl in range(1, 7):                     # the world one level brighter, with a warm cast
        for i in range(16):
            src = base[min(6, lvl + 1) * 16 + i]
            k = 1.25 if lvl == 6 else 1.08
            flash[lvl * 16 + i] = (min(31, int(src[0] * k + 1.5)), min(31, int(src[1] * k + 0.8)), min(31, int(src[2] * k)))
    for e in range(14 * 16 + 1, 16 * 16):
        c = base[e]
        flash[e] = (min(31, int(c[0] * 1.35 + 1.5)), min(31, int(c[1] * 1.3 + 0.8)), min(31, int(c[2] * 1.3)))
    pals = [base, hurt, pick, flash]
    return pals, b"".join(bytes(v for c in p for v in c) for p in pals)


# ---------------------------------------------------------------- output
def db(data, per=16):
    data = bytes(data)
    return "\n".join("        db " + ", ".join(str(b) for b in data[i:i + per]) for i in range(0, len(data), per))


def dw(words, per=8):
    return "\n".join("        dw " + ", ".join(str(w & 0xFFFF) for w in words[i:i + per]) for i in range(0, len(words), per))


def main():
    os.makedirs(os.path.join(OUT, "inc"), exist_ok=True)
    tex = build_texture()
    open(os.path.join(OUT, "tex.bin"), "wb").write(tex)
    pals, palbin = build_palettes()
    open(os.path.join(OUT, "palettes.bin"), "wb").write(palbin)

    faces, cells = compute_pvs()
    lists = build_pvs_lists(faces)
    stats = pvs_stats(lists)
    nextstep, ns_row = build_nextstep()
    vis, vis_row = build_vis(cells)
    open(os.path.join(OUT, "nextstep.bin"), "wb").write(nextstep)
    open(os.path.join(OUT, "vis.bin"), "wb").write(vis)

    # the face lists, packed into 16 KB banks (a list never crosses a bank)
    PVS_BANK0 = 3
    banks, ptr = [bytearray()], bytearray()
    for near, far in lists:
        blob = bytes([len(near)]) + b"".join(near) + bytes([len(far)]) + b"".join(far)
        assert len(near) < 256 and len(far) < 256
        if len(banks[-1]) + len(blob) > 16384:
            banks.append(bytearray())
        addr = 0x8000 + len(banks[-1])
        ptr += bytes([PVS_BANK0 + len(banks) - 1, addr & 255, addr >> 8])
        banks[-1] += blob
    for n, b in enumerate(banks):
        open(os.path.join(OUT, f"pvs_{n}.bin"), "wb").write(bytes(b))
    open(os.path.join(OUT, "pvsptr.bin"), "wb").write(bytes(ptr))
    TEX_BANK0 = PVS_BANK0 + len(banks)
    ROM_BANKS = 16
    while ROM_BANKS < TEX_BANK0 + 8:
        ROM_BANKS *= 2
    bk = ["; generated by tools/gen_data.py - do not edit", "; banks 3 and up: the face lists, the texture area, padding"]
    for n in range(len(banks)):
        bk += ["        org 0x8000", f'        incbin "out/pvs_{n}.bin"', "        ds 0xC000 - $, 0xFF"]
    bk += ["        org 0x8000", '        incbin "out/tex.bin"']
    for n in range(ROM_BANKS - TEX_BANK0 - 8):
        bk += ["        org 0x8000", "        ds 0x4000, 0xFF"]
    open(os.path.join(OUT, "inc", "banks.asm"), "w").write("\n".join(bk) + "\n")

    # spawns
    player = None
    enemies, items = [], []
    for z in range(MAP_H):
        for x in range(MAP_W):
            ch = MAP[z][x]
            pos = (x * CELL + CELL // 2, z * CELL + CELL // 2)
            if ch == "P":
                player = pos
            elif ch in ENEMY_CH:
                enemies.append((ENEMY_CH[ch],) + pos)
            elif ch == "+":
                items.append(pos)

    grid = bytes((WALL_TEX[MAP[z][x]] + 1) if MAP[z][x] in WALL_TEX else 0
                 for z in range(MAP_H) for x in range(MAP_W))
    cellidx = bytes(FREE_IDX.get((x, z), 255) for z in range(MAP_H) for x in range(MAP_W))
    assert NFREE < 255

    c = []
    eq = lambda n, v: c.append(f"{n}:{' ' * max(1, 15 - len(n))}equ {v}")
    c.append("; generated by tools/gen_data.py - do not edit")
    for n, v in (("MAP_W", MAP_W), ("MAP_H", MAP_H), ("NFREE", NFREE), ("VIS_ROW", vis_row),
                 ("NS_ROW", ns_row), ("PVS_BANK0", PVS_BANK0), ("PVS_BANKS", len(banks)),
                 ("TEX_BANK0", TEX_BANK0), ("TEX_BANKS", 8), ("ROM_BANKS", ROM_BANKS),
                 ("G3_F", FOCAL), ("G3_CX", CX), ("G3_CY", CY), ("G3_ZNEAR", ZNEAR),
                 ("G3_W", VIEW_W), ("G3_H", VIEW_H), ("EYE", EYE), ("WALL_H", WALL_H),
                 ("ZCLIP32", ZCLIP * ZSCALE), ("TEXY", TEXY), ("TSTRIDE", TSTRIDE),
                 ("YAW_MARGIN", YAW_MARGIN), ("VMAX_STATIC", VMAX_STATIC), ("FMAX_STATIC", FMAX_STATIC),
                 ("NENEMY", len(enemies)), ("NITEM", len(items)),
                 ("START_X", player[0]), ("START_Z", player[1]), ("START_YAW", 64),
                 ("NBANDS", 2 * NB), ("PISTOL_U", 192), ("PISTOL_V", TEXY), ("FLASH_U", 224), ("FLASH_V", TEXY + 256)):
        eq(n, v)
    for name, i in FRAME_ID.items():
        eq("FR_" + name.upper(), i)
    for i, (name, voice, data) in enumerate(SFX):
        eq("SFX_" + name.upper(), i)
    eq("CORNERS", (MAP_W + 1) * (MAP_H + 1))
    assert stats["near_max"] <= 32
    open(os.path.join(OUT, "inc", "const.asm"), "w").write("\n".join(c) + "\n")

    t = ["; generated by tools/gen_data.py - do not edit", "",
         "; sin(2 pi a / 256) in Q2.14; cos a = sin (a + 64)", "sin_tab:"]
    t.append(dw([sin_q14(a) for a in range(256)]))
    t += ["", "; the map: 0 free, else wall texture + 1 (MAP_W bytes a row)", "map_grid:", db(grid, MAP_W)]
    t += ["", "; the free cells' numbers (255 = wall)", "map_cellidx:", db(cellidx, MAP_W)]
    t += ["", "; row offsets into map_grid / map_cellidx, and into the corner map (MAP_W + 1 a row)",
          "map_row:", dw([z * MAP_W for z in range(MAP_H)]),
          "corner_row:", dw([z * (MAP_W + 1) for z in range(MAP_H + 1)])]
    t += ["", "; sound effects: dw data, db voice ; data: flags|volume, period lo, hi, noise ; FFh ends", "sfx_tab:"]
    for name, voice, data in SFX:
        t.append(f"        dw sfx_{name}")
        t.append(f"        db {voice}")
    for name, voice, data in SFX:
        t += [f"sfx_{name}:", db(data, 4), "        db 255"]
    t += ["", "; the normal's Y that makes geo3d pick light level n", "ny_tab:",
          dw([ny_of(l) for l in range(LEVELS)])]
    t += ["", "; billboard frames: u0, v0, w - 1, h - 1, dw normal Y, half width, y0, y1", "frame_tab:"]
    for f in FRAMES:
        lvl = min(LEVELS - 1, f["sy"] // 64)
        v0 = f["sy"] - 64 * lvl
        assert v0 + f["h"] - 1 <= 255 and f["u0"] + f["w"] - 1 <= 255
        t.append(f"        db {f['u0']}, {v0}, {f['w'] - 1}, {f['h'] - 1}")
        t.append(f"        dw {ny_of(lvl)}, {f['halfw']}, {f['y0']}, {f['y1']}        ; {f['name']}")
    t += ["", "; enemies at the start: type (0 fiend, 1 zombie), dw x, z", "spawn_enemies:"]
    for e in enemies:
        t.append(f"        db {e[0]}")
        t.append(f"        dw {e[1]}, {e[2]}")
    t += ["", "; medkits: dw x, z", "spawn_items:"]
    for it in items:
        t.append(f"        dw {it[0]}, {it[1]}")
    t += ["", "; floor and ceiling bands: dw DY (page 0), NY ; db colour", "band_tab:"]
    for k in range(NB):
        t.append(f"        dw {CY - BANDS[k + 1]}, {BANDS[k + 1] - BANDS[k]}")
        t.append(f"        db {14 * 16 + 1 + k}")
    for k in range(NB):
        t.append(f"        dw {CY + BANDS[k]}, {BANDS[k + 1] - BANDS[k]}")
        t.append(f"        db {15 * 16 + 1 + k}")
    t += ["", "; the same bands as VDP commands, for page 0 then page 1: R#36..R#46 of each fill",
          "bg_cmds:"]
    for page in range(2):
        for k in range(2 * NB):
            dy = (CY - BANDS[k + 1]) if k < NB else (CY + BANDS[k - NB])
            ny = BANDS[k % NB + 1] - BANDS[k % NB]
            col = (14 if k < NB else 15) * 16 + 1 + k % NB
            t.append(f"        dw 0, {dy + 256 * page}, 256, {ny}")
            t.append(f"        db {col}, 0, 0xC0")
    open(os.path.join(OUT, "inc", "tables.asm"), "w").write("\n".join(t) + "\n")

    json.dump(dict(map=MAP, free=FREE, lists=[[b"".join(n).hex(), b"".join(f).hex()] for n, f in lists],
                   frames=FRAMES, frame_id=FRAME_ID, enemies=enemies, items=items, player=player,
                   bands=BANDS, vis_row=vis_row, ns_row=ns_row, stats=stats),
              open(os.path.join(OUT, "world.json"), "w"))

    # previews
    indexed_png(os.path.join(OUT, "preview_tex.png"), 256, 512, tex, pals[0], 2)
    sw = bytearray()
    for p in range(4):
        for row in range(16):
            for _ in range(6):
                sw += bytes(row * 16 + i for i in range(16) for _ in range(8))
    lut = b"".join(bytes(((v << 3) | (v >> 2)) for e in range(256) for v in pals[p][e]) for p in range(4))
    rgb = bytearray()
    for p in range(4):
        for k in range(16 * 6 * 128):
            e = sw[p * 16 * 6 * 128 + k]
            rgb += lut[p * 768 + 3 * e:p * 768 + 3 * e + 3]
    write_png(os.path.join(OUT, "preview_pal.png"), 128, 4 * 96, bytes(rgb))

    nfaces = len(set().union(*faces))
    print(f"map {MAP_W}x{MAP_H}, {NFREE} free cells, {nfaces} wall faces, {len(enemies)} enemies, {len(items)} medkits")
    print(f"face lists: {sum(len(b) for b in banks)} bytes in {len(banks)} banks; "
          f"nextstep {len(nextstep)} bytes, vis {len(vis)} bytes")
    print("visibility:", stats)
    if stats["truncated_views"]:
        print("  note: some views exceed the far-face budget; their farthest faces are dropped")


if __name__ == "__main__":
    main()
