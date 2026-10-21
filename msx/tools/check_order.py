#!/usr/bin/env python3
"""check_order.py [poses] [seed] - how often does geo3d's painter's order go wrong?

geo3d has no depth buffer: it sorts the faces by the sum of their four
vertices' depths and paints far to near. This tool takes random poses (the
player anywhere he can stand, any yaw, the monsters anywhere they can stand),
builds the frame as the cartridge does (sim.build_frame) and, for every pixel,
compares the face the painter's order leaves on top with the face a depth
buffer would (nearest plane along the pixel's ray, holes of the texture not
counted). Prints the poses with wrong pixels and the totals.
"""
import random
import sys

import sim
from common import *
from sim import W, MAP, FREE_IDX, FRAMES

sys.path.insert(0, sim.GEO3D + "/sim")
from gen_scenes import render_faces            # noqa: E402
from gen_vectors import model as core_model    # noqa: E402


def is_wall(x, z):
    return MAP[z][x] in WALL_TEX


def can_stand(x, z, r):
    return not any(is_wall(int((x + dx) // CELL), int((z + dz) // CELL))
                   for dx in (-r, r) for dz in (-r, r))


def random_spot(rng, r):
    while True:
        cx, cz = rng.choice(W["free"])
        x, z = cx * CELL + rng.randrange(CELL), cz * CELL + rng.randrange(CELL)
        if can_stand(x, z, r):
            return x, z


def cam_point(cfg, v):
    m, t = cfg[0:9], cfg[9:12]
    return [((m[3 * r] * v[0] + m[3 * r + 1] * v[1] + m[3 * r + 2] * v[2]) >> 14) + t[r] for r in range(3)]


def check(px, pz, yaw, sprites):
    cfg, sc = sim.build_frame(px, pz, yaw, sprites)
    tex = sim.TEX
    order = []
    for idx, f in enumerate(sc.faces):
        one = dict(on=True, texx=0, texy=TEXY, tstride=TSTRIDE, uv=[sc.uvs[idx]])
        cmds, skip, draw, cull = render_faces(cfg, sc.verts, [f], 8, 0, [0, 16384, 0], one)
        if not draw:
            continue
        key = sum(core_model(cfg, sc.verts[f[k]])[2] for k in range(4))
        # the face's plane in camera space: n . P = d
        p0, p1, p3 = (cam_point(cfg, sc.verts[f[k]]) for k in (0, 1, 3))
        a = [p1[i] - p0[i] for i in range(3)]
        b = [p3[i] - p0[i] for i in range(3)]
        n = (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
        d = sum(n[i] * p0[i] for i in range(3))
        pix = []                                # (x, y) with a solid texel
        for c in cmds:
            sx = (c[0] | (c[1] << 8)) << 8
            sy = (c[2] | (c[3] << 8)) << 8
            dx, dy = c[4] | (c[5] << 8), c[6] | (c[7] << 8)
            nx = c[8] | (c[9] << 8)
            vx = c[14] | (c[15] << 8)
            vy = c[16] | (c[17] << 8)
            vx -= 65536 if vx & 0x8000 else 0
            vy -= 65536 if vy & 0x8000 else 0
            for _ in range(nx):
                if tex[((((sy >> 8) & 0x3FF) - TEXY) << 8) | ((sx >> 8) & 0xFF)]:
                    pix.append((dx, dy))
                dx += 1
                if dx > 255:
                    break
                sx = (sx + vx) & 0xFFFFF
                sy = (sy + vy) & 0x1FFFFF
        order.append((-key, idx, n, d, pix))
    order.sort(key=lambda e: (e[0], e[1]))
    top = {}                                    # painter: the depth of the last one painted
    near = {}                                   # depth buffer: the smallest depth
    for _, idx, n, d, pix in order:
        for (x, y) in pix:
            den = n[0] * (x - CX) / FOCAL - n[1] * (y - CY) / FOCAL + n[2]
            z = d / den if den else 1e9
            top[(x, y)] = z
            if (x, y) not in near or z < near[(x, y)]:
                near[(x, y)] = z
    # wrong: what is on top is clearly behind something else painted there (faces
    # that meet at an edge, or strips of one wall, share pixels at the same depth)
    wrong = [p for p in top if top[p] > near[p] * 1.03 + 3]
    return len(wrong), len(top), wrong


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 9968)
    bad_poses = bad_px = total_px = 0
    worst = (0, None)
    for i in range(n):
        px, pz = random_spot(rng, 57)
        yaw = rng.randrange(256)
        sprites = []
        for k in range(len(W["enemies"])):
            while True:
                x, z = random_spot(rng, 73)
                if abs(x - px) + abs(z - pz) > 150:
                    break
            sprites.append((rng.choice((0, 6)) + rng.choice((0, 1, 2, 3, 4, 5)), x, z))
        sprites = [s for s in sprites if sim.sees(px, pz, s[1], s[2])]
        w, t, pix = check(px, pz, yaw, sprites)
        total_px += t
        if w:
            bad_poses += 1
            bad_px += w
            if w > worst[0]:
                worst = (w, (px, pz, yaw, sprites))
            print(f"pose {i}: x={px / 256:.2f} z={pz / 256:.2f} yaw={yaw}: {w} of {t} pixels in the wrong order")
    print(f"{n} poses: {bad_poses} with pixels in the wrong order; {bad_px} of {total_px} pixels "
          f"({100.0 * bad_px / max(1, total_px):.3f} %)")
    if worst[1]:
        px, pz, yaw, sprites = worst[1]
        page, _ = sim.render_page(px, pz, yaw, sprites)
        indexed_png(os.path.join(OUT, "order_worst.png"), 256, VIEW_H, page, sim.palette(), 2)
        print(f"worst: {worst[0]} pixels, x={px / 256:.2f} z={pz / 256:.2f} yaw={yaw} -> out/order_worst.png")


if __name__ == "__main__":
    main()
