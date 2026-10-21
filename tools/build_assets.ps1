# MSXDOOM asset pipeline: Higgsfield source PNGs -> V9968 / Geo3D friendly assets.
#
#   powershell -ExecutionPolicy Bypass -File tools\build_assets.ps1
#
# Input : assets\src\*.png      (1024 px originals generated with Higgsfield)
# Output: assets\msx\*.idx      one byte per pixel, local colour index 0..15
#         assets\msx\*.png      preview of each converted asset (exact palette colours)
#         assets\msx\palette.pal 256 entries x 3 bytes (R,G,B, 5 bits each) = V9968 EPAL order
#         assets\msx\world_atlas.sc8  256x448 SCREEN 8 pixels: world textures x 7 light copies
#         assets\msx\manifest.json
#         assets\msx\_preview.png contact sheet
#         js\assets.js          everything above embedded for the browser prototype
#
# Target (see README): SCREEN 8 + EPAL, 256 x 15-bit palette organised as 16 sets of 16 colours.
#   sets 0-6  world textures, one set per Geo3D light level (0 = darkest, 6 = full bright)
#   sets 7-12 sprite mode 3 palette sets (colour 0 transparent, 15 colours per sprite sheet)
#   set  13   HUD / system colours (classic TMS9918 palette)
# No Python/Node needed: plain Windows PowerShell 5.1 + System.Drawing.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$csharp = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class Img {
    public int W, H;
    public float[] R, G, B, A;   // straight alpha, 0..1
    public Img(int w, int h) { W = w; H = h; R = new float[w * h]; G = new float[w * h]; B = new float[w * h]; A = new float[w * h]; }
}

public static class MsxArt {
    public static Img Load(string path) {
        using (Bitmap src = new Bitmap(path)) {
            int w = src.Width, h = src.Height;
            BitmapData bd = src.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            byte[] buf = new byte[bd.Stride * h];
            Marshal.Copy(bd.Scan0, buf, 0, buf.Length);
            src.UnlockBits(bd);
            Img im = new Img(w, h);
            for (int y = 0; y < h; y++) {
                int o = y * bd.Stride;
                for (int x = 0; x < w; x++, o += 4) {
                    int i = y * w + x;
                    im.B[i] = buf[o] / 255f; im.G[i] = buf[o + 1] / 255f; im.R[i] = buf[o + 2] / 255f; im.A[i] = buf[o + 3] / 255f;
                }
            }
            return im;
        }
    }

    public static void SavePng(Img im, string path) {
        using (Bitmap bmp = new Bitmap(im.W, im.H, PixelFormat.Format32bppArgb)) {
            BitmapData bd = bmp.LockBits(new Rectangle(0, 0, im.W, im.H), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            byte[] buf = new byte[bd.Stride * im.H];
            for (int y = 0; y < im.H; y++) {
                int o = y * bd.Stride;
                for (int x = 0; x < im.W; x++, o += 4) {
                    int i = y * im.W + x;
                    buf[o] = B8(im.B[i]); buf[o + 1] = B8(im.G[i]); buf[o + 2] = B8(im.R[i]); buf[o + 3] = B8(im.A[i]);
                }
            }
            Marshal.Copy(buf, 0, bd.Scan0, buf.Length);
            bmp.UnlockBits(bd);
            bmp.Save(path, ImageFormat.Png);
        }
    }

    static byte B8(float v) { int i = (int)Math.Round(v * 255.0); return (byte)(i < 0 ? 0 : (i > 255 ? 255 : i)); }

    // Box resample of the source rectangle (x0,y0,w,h) to dw x dh. 'core' (0..1] shrinks each
    // sampling box around its centre: the sources are fake pixel art made of ~8 px blocks, so
    // sampling only the middle of each box keeps edges crisp instead of blending neighbours.
    public static Img Resample(Img s, double x0, double y0, double w, double h, int dw, int dh, double core) {
        Img d = new Img(dw, dh);
        double bw = w / dw, bh = h / dh;
        for (int dy = 0; dy < dh; dy++) {
            double cy = y0 + (dy + 0.5) * bh, ya = cy - bh * core / 2, yb = cy + bh * core / 2;
            for (int dx = 0; dx < dw; dx++) {
                double cx = x0 + (dx + 0.5) * bw, xa = cx - bw * core / 2, xb = cx + bw * core / 2;
                double sr = 0, sg = 0, sb = 0, sa = 0, sw = 0;
                for (int iy = (int)Math.Floor(ya); iy < (int)Math.Ceiling(yb); iy++) {
                    double wy = Math.Min(iy + 1, yb) - Math.Max(iy, ya);
                    if (wy <= 0) continue;
                    for (int ix = (int)Math.Floor(xa); ix < (int)Math.Ceiling(xb); ix++) {
                        double wx = Math.Min(ix + 1, xb) - Math.Max(ix, xa);
                        if (wx <= 0) continue;
                        double wt = wx * wy;
                        sw += wt;
                        if (ix < 0 || iy < 0 || ix >= s.W || iy >= s.H) continue;   // outside = transparent
                        int i = iy * s.W + ix;
                        double a = s.A[i] * wt;
                        sr += s.R[i] * a; sg += s.G[i] * a; sb += s.B[i] * a; sa += a;
                    }
                }
                int o = dy * dw + dx;
                if (sa > 1e-9) { d.R[o] = (float)(sr / sa); d.G[o] = (float)(sg / sa); d.B[o] = (float)(sb / sa); }
                d.A[o] = sw > 0 ? (float)(sa / sw) : 0f;
            }
        }
        return d;
    }

    // Bounding box of pixels with alpha above the threshold: {x0, y0, x1, y1} (x1/y1 exclusive).
    public static int[] BBox(Img s, float thr) {
        int x0 = s.W, y0 = s.H, x1 = 0, y1 = 0;
        for (int y = 0; y < s.H; y++) for (int x = 0; x < s.W; x++) {
            if (s.A[y * s.W + x] > thr) { if (x < x0) x0 = x; if (y < y0) y0 = y; if (x + 1 > x1) x1 = x + 1; if (y + 1 > y1) y1 = y + 1; }
        }
        if (x1 <= x0) return new int[] { 0, 0, s.W, s.H };
        return new int[] { x0, y0, x1, y1 };
    }

    // Crop the opaque subject, scale it to fit maxW x maxH and place it on a cw x ch canvas.
    // bottom = true anchors the feet on the last row (billboards stand on the floor).
    public static Img FitSprite(Img s, int cw, int ch, int maxW, int maxH, bool bottom, double core) {
        int[] bb = BBox(s, 0.5f);
        double bw = bb[2] - bb[0], bh = bb[3] - bb[1];
        double sc = Math.Min(maxW / bw, maxH / bh);
        int dw = Math.Max(1, (int)Math.Round(bw * sc)), dh = Math.Max(1, (int)Math.Round(bh * sc));
        Img part = Resample(s, bb[0], bb[1], bw, bh, dw, dh, core);
        Img d = new Img(cw, ch);
        int ox = (cw - dw) / 2, oy = bottom ? ch - dh : (ch - dh) / 2;
        for (int y = 0; y < dh; y++) for (int x = 0; x < dw; x++) {
            int si = y * dw + x, di = (y + oy) * cw + (x + ox);
            d.R[di] = part.R[si]; d.G[di] = part.G[si]; d.B[di] = part.B[si]; d.A[di] = part.A[si];
        }
        return d;
    }

    static int To555(float r, float g, float b) {
        int r5 = Clamp((int)Math.Round(r * 31.0), 0, 31), g5 = Clamp((int)Math.Round(g * 31.0), 0, 31), b5 = Clamp((int)Math.Round(b * 31.0), 0, 31);
        return (r5 << 10) | (g5 << 5) | b5;
    }
    static int Clamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
    public static int Rgb555(int r8, int g8, int b8) { return To555(r8 / 255f, g8 / 255f, b8 / 255f); }

    static double Dist(double r, double g, double b, double r2, double g2, double b2) {
        double dr = r - r2, dg = g - g2, db = b - b2;
        return 3 * dr * dr + 4 * dg * dg + 2 * db * db;
    }

    // Histogram (rgb555 -> count) of every opaque pixel of the given images.
    public static Dictionary<int, int> Histogram(Img[] imgs) {
        Dictionary<int, int> h = new Dictionary<int, int>();
        foreach (Img im in imgs) for (int i = 0; i < im.W * im.H; i++) {
            if (im.A[i] < 0.5f) continue;
            int c = To555(im.R[i], im.G[i], im.B[i]);
            int n; h.TryGetValue(c, out n); h[c] = n + 1;
        }
        return h;
    }

    class Box { public List<int> Cols = new List<int>(); public double Err; public int Axis; public double Mean; }

    static void Measure(Box b, Dictionary<int, int> hist) {
        double[] sum = new double[3], sq = new double[3]; double n = 0;
        foreach (int c in b.Cols) {
            int w = hist[c]; double[] v = { (c >> 10) & 31, (c >> 5) & 31, c & 31 };
            for (int k = 0; k < 3; k++) { sum[k] += v[k] * w; sq[k] += v[k] * v[k] * w; }
            n += w;
        }
        double[] wt = { 3, 4, 2 }; double best = -1; b.Err = 0;
        for (int k = 0; k < 3; k++) {
            double var = (sq[k] - sum[k] * sum[k] / n) * wt[k];
            b.Err += var;
            if (var > best) { best = var; b.Axis = k; b.Mean = sum[k] / n; }
        }
    }

    // Median-cut style split followed by k-means refinement, all in 15-bit colour space.
    // 'fixedCols' are reserved entries (kept exactly); result has exactly n rgb555 values,
    // fixed colours first, the rest sorted from dark to bright.
    public static int[] BuildPalette(Dictionary<int, int> hist, int n, int[] fixedCols) {
        int k = n - fixedCols.Length;
        List<Box> boxes = new List<Box>();
        Box first = new Box(); first.Cols.AddRange(hist.Keys); Measure(first, hist); boxes.Add(first);
        while (boxes.Count < k) {
            Box worst = null;
            foreach (Box b in boxes) if (b.Cols.Count > 1 && (worst == null || b.Err > worst.Err)) worst = b;
            if (worst == null) break;
            Box lo = new Box(), hi = new Box();
            foreach (int c in worst.Cols) {
                int v = worst.Axis == 0 ? (c >> 10) & 31 : (worst.Axis == 1 ? (c >> 5) & 31 : c & 31);
                if (v <= worst.Mean) lo.Cols.Add(c); else hi.Cols.Add(c);
            }
            if (lo.Cols.Count == 0 || hi.Cols.Count == 0) { worst.Err = -1; continue; }
            Measure(lo, hist); Measure(hi, hist);
            boxes.Remove(worst); boxes.Add(lo); boxes.Add(hi);
        }
        List<double[]> cen = new List<double[]>();
        foreach (int c in fixedCols) cen.Add(new double[] { (c >> 10) & 31, (c >> 5) & 31, c & 31 });
        foreach (Box b in boxes) {
            double r = 0, g = 0, bl = 0, w = 0;
            foreach (int c in b.Cols) { int q = hist[c]; r += ((c >> 10) & 31) * q; g += ((c >> 5) & 31) * q; bl += (c & 31) * q; w += q; }
            cen.Add(new double[] { r / w, g / w, bl / w });
        }
        for (int it = 0; it < 16; it++) {
            double[][] acc = new double[cen.Count][];
            for (int i = 0; i < cen.Count; i++) acc[i] = new double[4];
            foreach (KeyValuePair<int, int> kv in hist) {
                int c = kv.Key; double r = (c >> 10) & 31, g = (c >> 5) & 31, b = c & 31;
                int bi = 0; double bd = double.MaxValue;
                for (int i = 0; i < cen.Count; i++) { double d = Dist(r, g, b, cen[i][0], cen[i][1], cen[i][2]); if (d < bd) { bd = d; bi = i; } }
                acc[bi][0] += r * kv.Value; acc[bi][1] += g * kv.Value; acc[bi][2] += b * kv.Value; acc[bi][3] += kv.Value;
            }
            for (int i = fixedCols.Length; i < cen.Count; i++)
                if (acc[i][3] > 0) cen[i] = new double[] { acc[i][0] / acc[i][3], acc[i][1] / acc[i][3], acc[i][2] / acc[i][3] };
        }
        List<int> rest = new List<int>();
        for (int i = fixedCols.Length; i < cen.Count; i++)
            rest.Add((Clamp((int)Math.Round(cen[i][0]), 0, 31) << 10) | (Clamp((int)Math.Round(cen[i][1]), 0, 31) << 5) | Clamp((int)Math.Round(cen[i][2]), 0, 31));
        rest.Sort(delegate (int a, int b) { return Luma(a).CompareTo(Luma(b)); });
        int[] pal = new int[n];
        for (int i = 0; i < fixedCols.Length; i++) pal[i] = fixedCols[i];
        for (int i = 0; i < rest.Count && fixedCols.Length + i < n; i++) pal[fixedCols.Length + i] = rest[i];
        return pal;
    }

    static double Luma(int c) { return 0.30 * ((c >> 10) & 31) + 0.59 * ((c >> 5) & 31) + 0.11 * (c & 31); }

    // Nearest palette entry per pixel. With transparent = true index 0 is the colour key
    // (alpha below 50 %) and opaque pixels only use entries 1..15.
    public static byte[] MapIndices(Img im, int[] pal, bool transparent) {
        byte[] idx = new byte[im.W * im.H];
        for (int i = 0; i < idx.Length; i++) {
            if (transparent && im.A[i] < 0.5f) { idx[i] = 0; continue; }
            double r = im.R[i] * 31.0, g = im.G[i] * 31.0, b = im.B[i] * 31.0;
            int bi = 0; double bd = double.MaxValue;
            for (int p = transparent ? 1 : 0; p < pal.Length; p++) {
                double d = Dist(r, g, b, (pal[p] >> 10) & 31, (pal[p] >> 5) & 31, pal[p] & 31);
                if (d < bd) { bd = d; bi = p; }
            }
            idx[i] = (byte)bi;
        }
        return idx;
    }

    // Geo3D light level 0..6 applied to a colour. Darkness drifts toward red instead of
    // black: the red channel falls off slower than green/blue (Mars base emergency lighting).
    public static int Shade(int c, double t) {
        double r = ((c >> 10) & 31) / 31.0, g = ((c >> 5) & 31) / 31.0, b = (c & 31) / 31.0;
        double kr = 0.10 + 0.90 * Math.Pow(t, 1.15), kg = 0.02 + 0.98 * Math.Pow(t, 1.75);
        double lum = 0.30 * r + 0.59 * g + 0.11 * b;
        r = r * kr + lum * 0.16 * (1 - t) * t * 4;   // red spill, strongest at mid levels
        g = g * kg; b = b * kg;
        return To555((float)Math.Min(1, r), (float)g, (float)b);
    }

    // Paint an indexed image into an RGBA canvas (preview sheets).
    public static void Blit(Img dst, byte[] idx, int w, int h, int[] pal, bool transparent, int ox, int oy, int scale) {
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int p = idx[y * w + x];
            if (transparent && p == 0) continue;
            int c = pal[p];
            float r = Expand((c >> 10) & 31), g = Expand((c >> 5) & 31), b = Expand(c & 31);
            for (int sy = 0; sy < scale; sy++) for (int sx = 0; sx < scale; sx++) {
                int px = ox + x * scale + sx, py = oy + y * scale + sy;
                if (px < 0 || py < 0 || px >= dst.W || py >= dst.H) continue;
                int di = py * dst.W + px;
                dst.R[di] = r; dst.G[di] = g; dst.B[di] = b; dst.A[di] = 1f;
            }
        }
    }
    static float Expand(int v5) { return ((v5 << 3) | (v5 >> 2)) / 255f; }

    // Copy a local-index texture into an 8bpp VRAM image, adding the palette set offset.
    public static void PutAtlas(byte[] atlas, int atlasW, byte[] idx, int w, int h, int ox, int oy, int add) {
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) atlas[(oy + y) * atlasW + ox + x] = (byte)(add + idx[y * w + x]);
    }

    public static void Fill(Img dst, int r8, int g8, int b8) {
        for (int i = 0; i < dst.W * dst.H; i++) { dst.R[i] = r8 / 255f; dst.G[i] = g8 / 255f; dst.B[i] = b8 / 255f; dst.A[i] = 1f; }
    }
}
'@
Add-Type -TypeDefinition $csharp -ReferencedAssemblies System.Drawing

$root   = Split-Path $PSScriptRoot -Parent
$srcDir = Join-Path $root 'assets\src'
$outDir = Join-Path $root 'assets\msx'
New-Item -ItemType Directory -Force $outDir | Out-Null

# ---------------------------------------------------------------- manifest
# World textures: 'crop' = one repeat cell of the source (x, y, w, h in source pixels).
# Walls are 64x64 (one map cell wide, never tiled vertically); floor/ceiling 32x32.
$worldDefs = @(
    @{ name = 'wall_steel'; src = 'wall_steel.png';  crop = @(0, 0, 341, 341);     size = 64; at = @(0, 0) },
    @{ name = 'wall_tech';  src = 'wall_tech.png';   crop = @(256, 64, 512, 512);  size = 64; at = @(64, 0) },
    @{ name = 'wall_rock';  src = 'wall_rock.png';   crop = @(0, 512, 512, 512);   size = 64; at = @(128, 0) },
    @{ name = 'floor';      src = 'floor_plate.png'; crop = @(18, 13, 328, 328);   size = 32; core = 1.0; at = @(192, 0) },
    @{ name = 'ceil';       src = 'ceil_panel.png';  crop = @(30, 80, 410, 370);   size = 32; at = @(224, 0) },
    @{ name = 'ceil_light'; src = 'ceil_panel.png';  crop = @(256, 256, 512, 512); size = 32; at = @(192, 32) }
)
# Colours that must survive quantisation even though they cover few pixels (R,G,B 0-255).
$worldFixed = @(
    [MsxArt]::Rgb555(0, 0, 0),        # black
    [MsxArt]::Rgb555(255, 24, 16),    # emergency light red
    [MsxArt]::Rgb555(232, 160, 0)     # hazard stripe yellow
)

# Sprite sheets: every frame of a sheet shares one 15-colour + transparent palette set.
# canvas = sprite size (width is a multiple of 16: sprite mode 3 planes are 16 px wide),
# fit = max size of the subject inside the canvas, crop = optional source pre-crop.
$sheetDefs = @(
    @{ name = 'fiend'; set = 7; dimSet = 8; canvas = @(48, 64); bottom = $true; frames = @(
        @{ name = 'fiend_walk1';  src = 'fiend_walk1.png';  fit = @(48, 60) },
        @{ name = 'fiend_walk2';  src = 'fiend_walk2.png';  fit = @(48, 60) },
        @{ name = 'fiend_attack'; src = 'fiend_attack.png'; fit = @(48, 64) },
        @{ name = 'fiend_pain';   src = 'fiend_pain.png';   fit = @(48, 60) },
        @{ name = 'fiend_dying';  src = 'fiend_dying.png';  fit = @(48, 46) },
        @{ name = 'fiend_dead';   src = 'fiend_dead.png';   fit = @(48, 20) }) },
    @{ name = 'zombie'; set = 9; dimSet = 10; canvas = @(48, 64); bottom = $true; frames = @(
        @{ name = 'zombie_walk1';  src = 'zombie_walk1.png';  fit = @(48, 60) },
        @{ name = 'zombie_walk2';  src = 'zombie_walk2.png';  fit = @(48, 60) },
        @{ name = 'zombie_attack'; src = 'zombie_attack.png'; fit = @(48, 60) },
        @{ name = 'zombie_pain';   src = 'zombie_pain.png';   fit = @(48, 60) },
        @{ name = 'zombie_dying';  src = 'zombie_dying.png';  fit = @(48, 46) },
        @{ name = 'zombie_dead';   src = 'zombie_dead.png';   fit = @(48, 18) }) },
    @{ name = 'weapon'; set = 11; dimSet = 11; canvas = @(64, 128); bottom = $true; frames = @(
        @{ name = 'pistol'; src = 'pistol_idle.png'; fit = @(64, 128) }) },
    @{ name = 'fx'; set = 12; dimSet = 12; canvas = @(32, 32); bottom = $false; frames = @(
        @{ name = 'medkit';       src = 'medkit.png';       fit = @(30, 30) },
        @{ name = 'muzzle_flash'; src = 'muzzle_flash.png'; fit = @(32, 32); crop = @(0, 0, 1024, 600) }) }
)

# Set 13: the classic TMS9918 (MSX1) colours, used by the HUD overlay sprites.
$tms = @(@(0,0,0),@(0,0,0),@(33,200,66),@(94,220,120),@(84,85,237),@(125,118,252),@(212,82,77),@(66,235,245),
         @(252,85,84),@(255,121,120),@(212,193,84),@(230,206,128),@(33,176,59),@(201,91,186),@(204,204,204),@(255,255,255))

$CORE = 0.6          # sampling box core fraction (see Resample)
$DIM_LEVEL = 3.0     # light level used for the 'dim' sprite palette sets
$palette = New-Object 'int[]' 256   # rgb555 per entry
$assets = [ordered]@{}              # name -> @{ kind; w; h; set; dim; idx }

# ---------------------------------------------------------------- world
Write-Host 'World textures...'
$worldImgs = @()
foreach ($d in $worldDefs) {
    $src = [MsxArt]::Load((Join-Path $srcDir $d.src))
    $c = $d.crop
    $sampleBox = if ($d.core) { $d.core } else { $CORE }      # core = 1.0: full box average (less noise)
    $worldImgs += ,([MsxArt]::Resample($src, $c[0], $c[1], $c[2], $c[3], $d.size, $d.size, $sampleBox))
}
$worldPal = [MsxArt]::BuildPalette([MsxArt]::Histogram([Img[]]$worldImgs), 16, [int[]]$worldFixed)
for ($lvl = 0; $lvl -le 6; $lvl++) {
    for ($i = 0; $i -lt 16; $i++) { $palette[$lvl * 16 + $i] = [MsxArt]::Shade($worldPal[$i], $lvl / 6.0) }
}
for ($n = 0; $n -lt $worldDefs.Count; $n++) {
    $d = $worldDefs[$n]
    $assets[$d.name] = @{ kind = 'texture'; w = $d.size; h = $d.size; set = 0; dim = 0; at = $d.at
                          idx = [MsxArt]::MapIndices($worldImgs[$n], $worldPal, $false) }
    Write-Host ("  {0,-12} {1}x{1}" -f $d.name, $d.size)
}

# ---------------------------------------------------------------- sprites
Write-Host 'Sprite sheets...'
foreach ($s in $sheetDefs) {
    $imgs = @()
    foreach ($f in $s.frames) {
        $src = [MsxArt]::Load((Join-Path $srcDir $f.src))
        if ($f.crop) { $src = [MsxArt]::Resample($src, $f.crop[0], $f.crop[1], $f.crop[2], $f.crop[3], $f.crop[2], $f.crop[3], 1.0) }
        $imgs += ,([MsxArt]::FitSprite($src, $s.canvas[0], $s.canvas[1], $f.fit[0], $f.fit[1], $s.bottom, $CORE))
    }
    # 15 colours + entry 0 reserved as the transparent colour key
    $pal15 = [MsxArt]::BuildPalette([MsxArt]::Histogram([Img[]]$imgs), 15, [int[]]@())
    $pal = @(0) + $pal15
    for ($i = 0; $i -lt 16; $i++) {
        $palette[$s.set * 16 + $i] = $pal[$i]
        if ($s.dimSet -ne $s.set) { $palette[$s.dimSet * 16 + $i] = [MsxArt]::Shade($pal[$i], $DIM_LEVEL / 6.0) }
    }
    for ($n = 0; $n -lt $s.frames.Count; $n++) {
        $f = $s.frames[$n]
        $assets[$f.name] = @{ kind = 'sprite'; w = $s.canvas[0]; h = $s.canvas[1]; set = $s.set; dim = $s.dimSet
                              idx = [MsxArt]::MapIndices($imgs[$n], [int[]]$pal, $true) }
    }
    Write-Host ("  {0,-12} {1} frame(s) {2}x{3}, {4} sprite plane(s) each, palette set {5}" -f `
        $s.name, $s.frames.Count, $s.canvas[0], $s.canvas[1], ($s.canvas[0] / 16), $s.set)
}
for ($i = 0; $i -lt 16; $i++) { $palette[13 * 16 + $i] = [MsxArt]::Rgb555($tms[$i][0], $tms[$i][1], $tms[$i][2]) }

# ---------------------------------------------------------------- write files
function SetPalette([int]$set) { return [int[]]$palette[($set * 16)..($set * 16 + 15)] }

$palBytes = New-Object 'byte[]' 768
for ($i = 0; $i -lt 256; $i++) {
    $c = $palette[$i]
    $palBytes[$i * 3] = ($c -shr 10) -band 31; $palBytes[$i * 3 + 1] = ($c -shr 5) -band 31; $palBytes[$i * 3 + 2] = $c -band 31
}
[IO.File]::WriteAllBytes((Join-Path $outDir 'palette.pal'), $palBytes)

$manifest = [ordered]@{ target = 'V9968 SCREEN 8 + EPAL (256 x 15-bit), Geo3D textures, sprite mode 3'
                        palette = 'palette.pal: 256 x (R,G,B) 5-bit, 16 sets of 16'; assets = @() }
foreach ($name in $assets.Keys) {
    $a = $assets[$name]
    [IO.File]::WriteAllBytes((Join-Path $outDir "$name.idx"), [byte[]]$a.idx)
    $img = New-Object Img $a.w, $a.h
    $showSet = if ($a.kind -eq 'texture') { 6 } else { $a.set }
    [MsxArt]::Blit($img, [byte[]]$a.idx, $a.w, $a.h, (SetPalette $showSet), ($a.kind -eq 'sprite'), 0, 0, 1)
    [MsxArt]::SavePng($img, (Join-Path $outDir "$name.png"))
    $entry = [ordered]@{ name = $name; kind = $a.kind; file = "$name.idx"; width = $a.w; height = $a.h
                         paletteSet = $a.set; dimSet = $a.dim; bytes = $a.w * $a.h }
    if ($a.at) { $entry.atlasX = $a.at[0]; $entry.atlasY = $a.at[1] }
    $manifest.assets += $entry
}

# World atlas, ready for VRAM: Geo3D takes ONE texture origin per RUN (TEXX/TEXY) and 8-bit
# U,V, so every world texture lives in a single 256 x 64 block. It is stored as 7 pre-shaded
# copies TSTRIDE = 64 rows apart (copy n = light level n = palette set n): 256 x 448 bytes
# of SCREEN 8 pixels, e.g. loaded at page 2 (TEXY = 512).
$ATLAS_W = 256; $ATLAS_H = 64
$atlas = New-Object 'byte[]' ($ATLAS_W * $ATLAS_H * 7)
$atlasImg = New-Object Img $ATLAS_W, ($ATLAS_H * 7)
[MsxArt]::Fill($atlasImg, 0, 0, 0)
for ($lvl = 0; $lvl -le 6; $lvl++) {
    foreach ($d in $worldDefs) {
        $a = $assets[$d.name]
        [MsxArt]::PutAtlas($atlas, $ATLAS_W, [byte[]]$a.idx, $a.w, $a.h, $d.at[0], $lvl * $ATLAS_H + $d.at[1], $lvl * 16)
        [MsxArt]::Blit($atlasImg, [byte[]]$a.idx, $a.w, $a.h, (SetPalette $lvl), $false, $d.at[0], $lvl * $ATLAS_H + $d.at[1], 1)
    }
}
[IO.File]::WriteAllBytes((Join-Path $outDir 'world_atlas.sc8'), $atlas)
[MsxArt]::SavePng($atlasImg, (Join-Path $outDir 'world_atlas.png'))
$manifest.worldAtlas = [ordered]@{ file = 'world_atlas.sc8'; width = $ATLAS_W; height = $ATLAS_H * 7; format = '8bpp EPAL index'
                                   tstride = $ATLAS_H; copies = 7; note = 'copy n = light level n (0 darkest); TEXY = base + level * TSTRIDE' }
$utf8 = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $outDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), $utf8)

# palette swatch + contact sheet
$sw = New-Object Img 256, 256
$ramp = New-Object 'byte[]' 256; for ($i = 0; $i -lt 256; $i++) { $ramp[$i] = $i -band 15 }
for ($set = 0; $set -lt 16; $set++) {
    $row = New-Object 'byte[]' 16; for ($i = 0; $i -lt 16; $i++) { $row[$i] = $i }
    [MsxArt]::Blit($sw, $row, 16, 1, (SetPalette $set), $false, 0, $set * 16, 16)
}
[MsxArt]::SavePng($sw, (Join-Path $outDir 'palette.png'))

$sheet = New-Object Img 1304, 836
[MsxArt]::Fill($sheet, 48, 0, 48)
$x = 8; $y = 8
foreach ($name in @('wall_steel', 'wall_tech', 'wall_rock')) { [MsxArt]::Blit($sheet, [byte[]]$assets[$name].idx, 64, 64, (SetPalette 6), $false, $x, $y, 4); $x += 264 }
foreach ($name in @('floor', 'ceil', 'ceil_light')) { [MsxArt]::Blit($sheet, [byte[]]$assets[$name].idx, 32, 32, (SetPalette 6), $false, $x, $y, 4); $x += 136 }
# the same wall at light levels 6..0
$x = 800; $y = 144
for ($lvl = 6; $lvl -ge 0; $lvl--) { [MsxArt]::Blit($sheet, [byte[]]$assets['wall_tech'].idx, 64, 64, (SetPalette $lvl), $false, $x, $y, 1); $x += 62 }
# sprite sheets: 6 frames at full brightness, then walk1 again with the 'dim' palette set
$y = 280
foreach ($s in $sheetDefs[0..1]) {
    $x = 8
    foreach ($f in $s.frames) { [MsxArt]::Blit($sheet, [byte[]]$assets[$f.name].idx, 48, 64, (SetPalette $s.set), $true, $x, $y, 3); $x += 152 }
    [MsxArt]::Blit($sheet, [byte[]]$assets[$s.frames[0].name].idx, 48, 64, (SetPalette $s.dimSet), $true, $x, $y, 3)
    $y += 200
}
[MsxArt]::Blit($sheet, [byte[]]$assets['pistol'].idx, 64, 128, (SetPalette 11), $true, 1100, 280, 3)
[MsxArt]::Blit($sheet, [byte[]]$assets['medkit'].idx, 32, 32, (SetPalette 12), $true, 8, 690, 4)
[MsxArt]::Blit($sheet, [byte[]]$assets['muzzle_flash'].idx, 32, 32, (SetPalette 12), $true, 160, 690, 4)
[MsxArt]::SavePng($sheet, (Join-Path $outDir '_preview.png'))

# browser bundle: index data as base64, so the game runs from file:// with no fetch/decoding
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('// GENERATED by tools/build_assets.ps1 - do not edit by hand.')
[void]$sb.AppendLine('// Indexed art (one byte per pixel, local colour 0..15) + V9968 EPAL palette (256 x RGB555).')
[void]$sb.AppendLine('window.MSXDOOM_ASSETS = {')
[void]$sb.AppendLine("  palette: '" + [Convert]::ToBase64String($palBytes) + "',")
[void]$sb.AppendLine('  images: {')
$names = @($assets.Keys)
for ($n = 0; $n -lt $names.Count; $n++) {
    $a = $assets[$names[$n]]
    $comma = if ($n -lt $names.Count - 1) { ',' } else { '' }
    [void]$sb.AppendLine(("    {0}: {{ kind: '{1}', w: {2}, h: {3}, set: {4}, dim: {5}, data: '{6}' }}{7}" -f `
        $names[$n], $a.kind, $a.w, $a.h, $a.set, $a.dim, [Convert]::ToBase64String([byte[]]$a.idx), $comma))
}
[void]$sb.AppendLine('  }')
[void]$sb.AppendLine('};')
New-Item -ItemType Directory -Force (Join-Path $root 'js') | Out-Null
[IO.File]::WriteAllText((Join-Path $root 'js\assets.js'), $sb.ToString(), $utf8)

$texBytes = 0; $sprBytes = 0
foreach ($a in $assets.Values) { if ($a.kind -eq 'sprite') { $sprBytes += $a.w * $a.h / 2 } }
$texBytes = $atlas.Length
Write-Host ("Done. {0} assets. VRAM estimate: world atlas 256x448 (8bpp, 7 light copies) {1:N0} bytes, sprite patterns (4bpp) {2:N0} bytes." -f $assets.Count, $texBytes, $sprBytes)
