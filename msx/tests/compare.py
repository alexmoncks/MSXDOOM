#!/usr/bin/env python3
"""compare.py <dir> - the pages the emulator dumped (run.tcl, scenario poses)
against tools/sim.py, which runs the same scene through geo3d's reference model.

For every POSE line of log.txt: NAME.bin (256 x 212 bytes of SCREEN 8) and
the 256 x 180 view the model paints must be the same bytes. Writes NAME.cmp.png
(emulator | model | differences in white) and exits 1 if any pose differs.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import sim                                         # noqa: E402
from common import VIEW_H, write_png               # noqa: E402


def main():
    d = sys.argv[1]
    pal = sim.palette()
    lut = [bytes(((c << 3) | (c >> 2)) for c in e) for e in pal]
    bad = 0
    n = 0
    for line in open(os.path.join(d, "log.txt")):
        m = re.search(r"POSE (\S+) .* x=(\d+) z=(\d+) yaw=(\d+)", line)
        if not m:
            continue
        i = m.group(1)
        x, z, yaw = (int(v) for v in m.groups()[1:])
        got = open(os.path.join(d, f"{i}.bin"), "rb").read()[:256 * VIEW_H]
        want, st = sim.render_page(x, z, yaw, sim.all_sprites(x, z))
        diff = sum(1 for a, b in zip(got, want) if a != b)
        n += 1
        bad += diff != 0
        rgb = bytearray()
        for y in range(VIEW_H):
            row_g = got[y * 256:(y + 1) * 256]
            row_w = want[y * 256:(y + 1) * 256]
            rgb += b"".join(lut[p] for p in row_g) + b"".join(lut[p] for p in row_w)
            rgb += b"".join(b"\xff\xff\xff" if a != b else b"\0\0\0" for a, b in zip(row_g, row_w))
        write_png(os.path.join(d, f"{i}.cmp.png"), 768, VIEW_H, bytes(rgb))
        print(f"{i:8s} x={x / 256:6.2f} z={z / 256:6.2f} yaw={yaw:3d}: "
              f"{'OK  ' if diff == 0 else 'DIFF'} {diff:5d} pixels differ; model: {st['faces']} faces, "
              f"{st['verts']} vertices, {st['spans']} spans, {st['texels']} texels")
    print(f"{n - bad} of {n} poses identical to the reference model")
    sys.exit(1 if bad or not n else 0)


if __name__ == "__main__":
    main()
