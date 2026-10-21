#!/usr/bin/env python3
"""sim.py - the frame the cartridge draws, computed on the PC.

build_frame() is the specification of the Z80 renderer (src/render.asm): the
same integer arithmetic, the same order of vertices and faces. Its output goes
through geo3d's bit-exact reference model (geo3d/sim/gen_scenes.py) and a
SCREEN 8 model of LRMM, so the page it paints is what the hardware paints.

  sim.py x z yaw [out.png]      one frame; x, z in cells, yaw in 1/256 turn
  sim.py --tour                 a set of poses -> out/sim_*.png
tests/compare.py uses render_page() to check the emulator's VRAM.
"""
import json
import os
import sys

from common import *

GEO3D = os.environ.get("GEO3D") or os.path.join(os.path.dirname(ROOT), "V9968_Cartridge", "geo3d")
sys.path.insert(0, os.path.join(GEO3D, "sim"))
from gen_scenes import render_faces            # noqa: E402

W = json.load(open(os.path.join(OUT, "world.json")))
MAP = W["map"]
MAP_W, MAP_H = len(MAP[0]), len(MAP)
FREE_IDX = {tuple(c): i for i, c in enumerate(W["free"])}
TEX = open(os.path.join(OUT, "tex.bin"), "rb").read()
PALS = open(os.path.join(OUT, "palettes.bin"), "rb").read()
FRAMES = W["frames"]


def mulq14(a, b):
    """(a * b) >> 14 as the Z80 does it: on magnitudes, sign put back after."""
    p = (abs(a) * abs(b)) >> 14
    return -p if (a < 0) != (b < 0) else p


def ny_of(level):
    return 0 if level == 0 else level * 2341 + 100


def frac8(num, den):
    """floor(256 * num / den) for 0 <= num < den (8 steps of restoring division)."""
    q = 0
    for _ in range(8):
        num <<= 1
        q <<= 1
        if num >= den:
            num -= den
            q |= 1
    return q


class Scene:
    def __init__(self):
        self.verts, self.faces, self.uvs = [], [], []

    def vert(self, x, y, z):
        self.verts.append((x, y, z))
        return len(self.verts) - 1

    def face(self, i0, i1, i2, i3, ny, uv):
        self.faces.append((i0, i1, i2, i3, 0, ny, 0, 0x80))
        self.uvs.append(list(uv))


def camera(px, pz, yaw, eye=EYE):
    fx, fz = sin_q14(yaw), -sin_q14(yaw + 64)
    rx, rz = sin_q14(yaw + 64), sin_q14(yaw)
    m = [rx, 0, rz, 0, 16384, 0, fx, 0, fz]
    t = [-(mulq14(rx, px) + mulq14(rz, pz)), -eye, -(mulq14(fx, px) + mulq14(fz, pz))]
    return m, t, (fx, fz, rx, rz)


def add_near_static(sc, cell):
    """The walls of the 3 x 3 cells around the cell, each as four strips 64 units
    wide. They stay in geo3d while the player is in the cell: geo3d itself drops
    the strips with a vertex behind ZNEAR. -> per wall, its five vertex pairs."""
    near = bytes.fromhex(W["lists"][cell][0])
    pcx, pcz = W["free"][cell]
    corner = {}
    walls = []

    def vtx(i, j):
        if (i, j) not in corner:
            corner[(i, j)] = sc.vert((pcx - 1 + i) * CELL, WALL_H, (pcz - 1 + j) * CELL)
            sc.vert((pcx - 1 + i) * CELL, 0, (pcz - 1 + j) * CELL)
        return corner[(i, j)]

    for k in range(0, len(near), 2):
        b0, b1 = near[k], near[k + 1]
        i, j, d = b0 & 3, (b0 >> 2) & 3, b0 >> 4
        tex, lvl = b1 & 15, b1 >> 4
        idx = [vtx(i, j), 0, 0, 0, vtx(i + DIRS[d][0], j + DIRS[d][1])]
        ax, az = (pcx - 1 + i) * CELL, (pcz - 1 + j) * CELL
        for n in (1, 2, 3):
            x, z = ax + DIRS[d][0] * 64 * n, az + DIRS[d][1] * 64 * n
            idx[n] = sc.vert(x, WALL_H, z)
            sc.vert(x, 0, z)
        u = 64 * tex
        for n in range(4):
            a, b = idx[n], idx[n + 1]
            sc.face(a, b, b + 1, a + 1, ny_of(lvl),
                    (u + 16 * n, 0, u + 16 * n + 15, 0, u + 16 * n + 15, 63, u + 16 * n, 63))
        walls.append(idx)
    return walls


def add_static(sc, cell, build_yaw):
    """The far faces of the cell's list that the bearing test lets through."""
    far = bytes.fromhex(W["lists"][cell][1])
    corner = {}

    def vtx(cx, cz):
        if (cx, cz) not in corner:
            corner[(cx, cz)] = sc.vert(cx * CELL, WALL_H, cz * CELL)
            sc.vert(cx * CELL, 0, cz * CELL)
        return corner[(cx, cz)]

    for k in range(0, len(far), 5):
        ax, az, b2, a0, lim = far[k:k + 5]
        if (build_yaw - a0) % 256 > lim:
            continue
        d, tex, lvl = b2 & 3, (b2 >> 2) & 3, (b2 >> 4) & 7
        if len(sc.verts) > VMAX_STATIC - 6 or len(sc.faces) > FMAX_STATIC - 2:
            break
        a = vtx(ax, az)
        b = vtx(ax + DIRS[d][0], az + DIRS[d][1])
        u = 64 * tex
        if b2 & 0x80:                           # two halves, a vertex pair in the middle
            mx, mz = ax * CELL + DIRS[d][0] * 128, az * CELL + DIRS[d][1] * 128
            m = sc.vert(mx, WALL_H, mz)
            sc.vert(mx, 0, mz)
            sc.face(a, m, m + 1, a + 1, ny_of(lvl), (u, 0, u + 31, 0, u + 31, 63, u, 63))
            sc.face(m, b, b + 1, m + 1, ny_of(lvl), (u + 32, 0, u + 63, 0, u + 63, 63, u + 32, 63))
        else:
            sc.face(a, b, b + 1, a + 1, ny_of(lvl), (u, 0, u + 63, 0, u + 63, 63, u, 63))


def add_near(sc, cell, px, pz, cam, walls):
    """Every frame: for each near wall that crosses Z = ZCLIP, one face from the
    crossing to the end of the strip it falls in. geo3d may have dropped that
    strip (a vertex behind ZNEAR, or its projection overflowed); the strips
    farther along the wall are all in front and stay as they are."""
    fx, fz, rx, rz = cam
    near = bytes.fromhex(W["lists"][cell][0])
    pcx, pcz = px >> 8, pz >> 8
    dx0 = -(256 + (px & 255))
    dz0 = -(256 + (pz & 255))
    z00 = mulq14(fx, dx0 * ZSCALE) + mulq14(fz, dz0 * ZSCALE)
    sx, sz = fx >> 1, fz >> 1
    zg = [[z00 + i * sx + j * sz for j in range(4)] for i in range(4)]
    zc = ZCLIP * ZSCALE
    for w in range(len(near) // 2):
        b0, b1 = near[2 * w], near[2 * w + 1]
        i, j, d = b0 & 3, (b0 >> 2) & 3, b0 >> 4
        tex, lvl = b1 & 15, b1 >> 4
        za = zg[i][j]
        zb = zg[i + DIRS[d][0]][j + DIRS[d][1]]
        if (za < zc) == (zb < zc):
            continue                            # all in front, or all behind
        if len(sc.verts) > 253 or len(sc.faces) > 254:
            break
        ax, az = (pcx - 1 + i) * CELL, (pcz - 1 + j) * CELL
        u = 64 * tex
        idx = walls[w]
        if za < zc:                             # from the crossing to the next cut
            o = frac8(zc - za, zb - za) + 1
            if o > 255:
                continue
            n = o >> 6
            x, z = ax + DIRS[d][0] * o, az + DIRS[d][1] * o
            a = sc.vert(x, WALL_H, z)
            sc.vert(x, 0, z)
            b = idx[n + 1]
            ul, ur = u + (o >> 2), u + 16 * n + 15
        else:                                   # from the cut before it to the crossing
            e = 255 - frac8(zc - zb, za - zb)
            if e < 1:
                continue
            n = (e - 1) >> 6
            x, z = ax + DIRS[d][0] * e, az + DIRS[d][1] * e
            b = sc.vert(x, WALL_H, z)
            sc.vert(x, 0, z)
            a = idx[n]
            ul, ur = u + 16 * n, u + ((e - 1) >> 2)
        sc.face(a, b, b + 1, a + 1, ny_of(lvl), (ul, 0, ur, 0, ur, 63, ul, 63))


def add_billboard(sc, frame, x, z, cam):
    fx, fz, rx, rz = cam
    f = FRAMES[frame]
    ox, oz = mulq14(rx, f["halfw"]), mulq14(rz, f["halfw"])
    a = sc.vert(x - ox, f["y1"], z - oz)        # top left, bottom left, top right, bottom right
    sc.vert(x - ox, f["y0"], z - oz)
    sc.vert(x + ox, f["y1"], z + oz)
    sc.vert(x + ox, f["y0"], z + oz)
    lvl = min(LEVELS - 1, f["sy"] // 64)
    u0, v0 = f["u0"], f["sy"] - 64 * lvl
    u1, v1 = u0 + f["w"] - 1, v0 + f["h"] - 1
    sc.face(a, a + 2, a + 3, a + 1, ny_of(lvl), (u0, v0, u1, v0, u1, v1, u0, v1))


def build_frame(px, pz, yaw, sprites=(), build_yaw=None, eye=EYE):
    """px, pz: world units; sprites: (frame, x, z). -> (cfg, Scene)"""
    cell = FREE_IDX[(px >> 8, pz >> 8)]
    m, t, cam = camera(px, pz, yaw, eye)
    sc = Scene()
    walls = add_near_static(sc, cell)
    add_static(sc, cell, yaw if build_yaw is None else build_yaw)
    add_near(sc, cell, px, pz, cam, walls)
    for fr, x, z in sprites:
        if len(sc.verts) > 251 or len(sc.faces) > 254:
            break
        add_billboard(sc, fr, x, z, cam)
    assert len(sc.verts) <= 255 and len(sc.faces) <= 255, (len(sc.verts), len(sc.faces))
    return m + t + [FOCAL, CX, CY, ZNEAR, VIEW_W, VIEW_H], sc


def paint(vram, cmds):
    """LRMM spans (19 bytes) into a SCREEN 8 VRAM of 1024 rows."""
    for c in cmds:
        assert len(c) == 19
        sx = (c[0] | (c[1] << 8)) << 8
        sy = (c[2] | (c[3] << 8)) << 8
        dx, dy = c[4] | (c[5] << 8), c[6] | (c[7] << 8)
        nx = c[8] | (c[9] << 8)
        vx = c[14] | (c[15] << 8)
        vy = c[16] | (c[17] << 8)
        vx -= 65536 if vx & 0x8000 else 0
        vy -= 65536 if vy & 0x8000 else 0
        timp = c[18] & 8
        for _ in range(nx):
            src = vram[(((sy >> 8) & 0x3FF) << 8) | ((sx >> 8) & 0xFF)]
            if not (timp and src == 0):
                vram[((dy & 0x3FF) << 8) | (dx & 0xFF)] = src
            dx += 1
            if dx > 255:
                break
            sx = (sx + vx) & 0xFFFFF
            sy = (sy + vy) & 0x1FFFFF


def background(vram, page=0):
    b = W["bands"]
    for k in range(len(b) - 1):
        for y in range(CY - b[k + 1], CY - b[k]):
            vram[(page * 256 + y) * 256:(page * 256 + y + 1) * 256] = bytes([14 * 16 + 1 + k]) * 256
        for y in range(CY + b[k], CY + b[k + 1]):
            vram[(page * 256 + y) * 256:(page * 256 + y + 1) * 256] = bytes([15 * 16 + 1 + k]) * 256


def render_page(px, pz, yaw, sprites=(), build_yaw=None, weapon=True, eye=EYE):
    """-> (the 256 x 180 view as bytes, statistics)"""
    cfg, sc = build_frame(px, pz, yaw, sprites, build_yaw, eye)
    vram = bytearray(256 * 1024)
    vram[TEXY * 256:] = TEX
    background(vram)
    tex = dict(on=True, texx=0, texy=TEXY, tstride=TSTRIDE, uv=sc.uvs)
    cmds, skip, draw, cull = render_faces(cfg, sc.verts, sc.faces, 8, 0, [0, 16384, 0], tex)
    paint(vram, cmds)
    if weapon:
        for y in range(68):
            for x in range(64):
                p = vram[(TEXY + y) * 256 + 192 + x]
                if p:
                    vram[(VIEW_H - 68 + y) * 256 + 96 + x] = p
        for y in range(9):                      # the crosshair
            for x in range(9):
                p = vram[(TEXY + 384 + y) * 256 + 240 + x]
                if p:
                    vram[(CY - 4 + y) * 256 + CX - 4 + x] = p
    stats = dict(verts=len(sc.verts), faces=len(sc.faces), skip=skip, draw=draw, cull=cull,
                 spans=len(cmds), texels=sum(c[8] | (c[9] << 8) for c in cmds))
    return bytes(vram[:256 * VIEW_H]), stats


VIS = open(os.path.join(OUT, "vis.bin"), "rb").read()


def sees(px, pz, x, z):
    """The cell-to-cell visibility bit the Z80 tests before it draws a billboard."""
    p = FREE_IDX[(px >> 8, pz >> 8)]
    e = FREE_IDX[(x >> 8, z >> 8)]
    return bool(VIS[p * W["vis_row"] + (e >> 3)] & (1 << (e & 7)))


def all_sprites(px, pz):
    sp = [(e[0] * 6, e[1], e[2]) for e in W["enemies"]] + [(12, i[0], i[1]) for i in W["items"]]
    return [s for s in sp if sees(px, pz, s[1], s[2])]


def palette(n=0):
    return [tuple(PALS[n * 768 + 3 * i:n * 768 + 3 * i + 3]) for i in range(256)]


def main():
    args = sys.argv[1:]
    if args and args[0] == "--tour":
        poses = [(2.5, 2.5, 64, "start"), (2.5, 3.5, 64, "door"), (7.5, 3.5, 64, "hall"),
                 (9.3, 4.6, 40, "hall2"), (13.5, 7.5, 0, "cross"), (20.5, 3.3, 200, "rock"),
                 (3.3, 11.2, 100, "south"), (2.25, 2.25, 224, "corner"), (10.5, 8.5, 128, "mid"),
                 (5.7, 3.5, 70, "doorway")]
        for x, z, yaw, name in poses:
            page, st = render_page(int(x * 256), int(z * 256), yaw, all_sprites(int(x * 256), int(z * 256)))
            indexed_png(os.path.join(OUT, f"sim_{name}.png"), 256, VIEW_H, page, palette(), 2)
            print(name, st)
        return
    x, z, yaw = float(args[0]), float(args[1]), int(args[2])
    out = args[3] if len(args) > 3 else os.path.join(OUT, "sim.png")
    page, st = render_page(int(x * 256), int(z * 256), yaw, all_sprites(int(x * 256), int(z * 256)))
    indexed_png(out, 256, VIEW_H, page, palette(), 2)
    print(st)


if __name__ == "__main__":
    main()
