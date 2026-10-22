#!/usr/bin/env python3
"""Render an Osmosis .poly boundary onto a static basemap image.

Stdlib only (no numpy/PIL/folium). Fetches OSM raster tiles once, embeds them
into a self-contained SVG, then rasterizes it with headless Chromium.

  python3 scripts/render-valle-central-poly.py

Writes data/valle_central_boundary.svg and data/valle_central_boundary.png.
"""

import argparse
import base64
import math
import os
import shutil
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BASEMAPS = {
    "osm": "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    "topo": "https://a.tile.opentopomap.org/{z}/{x}/{y}.png",
}

PLAN_BBOX = (-84.45, 9.65, -83.65, 10.25)
SEEDS = [
    (9.9325, -84.0796),
    (10.0162, -84.2116),
    (9.9981, -84.1165),
    (9.8644, -83.9194),
    (10.0875, -84.4700),
    (9.8383, -83.8656),
]

TILE = 256
TILE_LIMIT = 2 ** 31


def parse_poly(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [ln.strip() for ln in fh if ln.strip()]
    if len(lines) < 2:
        raise SystemExit(f"not an Osmosis .poly: {path}")
    try:
        rings = int(lines[1])
    except ValueError:
        raise SystemExit(f"missing ring count in {path}")
    points = []
    for ln in lines[2:]:
        if ln.upper() == "END":
            continue
        parts = ln.split()
        if len(parts) != 2:
            continue
        try:
            lon, lat = float(parts[0]), float(parts[1])
        except ValueError:
            continue
        points.append((lon, lat))
    if len(points) < 3:
        raise SystemExit(f"no usable ring in {path}")
    return rings, points


def project(lon, lat, zoom):
    world = TILE * (2 ** zoom)
    x = (lon + 180.0) / 360.0 * world
    s = math.sin(math.radians(max(-85.05112878, min(85.05112878, lat))))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * world
    return x, y


def pixel_bbox(points, zoom):
    xs, ys = [], []
    for lon, lat in points:
        x, y = project(lon, lat, zoom)
        xs.append(x)
        ys.append(y)
    return min(xs), min(ys), max(xs), max(ys)


def choose_zoom(points, max_px, pad, min_z, max_z):
    for zoom in range(max_z, min_z - 1, -1):
        x0, y0, x1, y1 = pixel_bbox(points, zoom)
        w = (x1 - x0) + 2 * pad
        h = (y1 - y0) + 2 * pad
        if w <= max_px and h <= max_px:
            return zoom
    return min_z


def fetch_tile(url_tpl, zoom, x, y, cache_dir, ua):
    path = os.path.join(cache_dir, str(zoom), str(x), f"{y}.png")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, "rb") as fh:
            return fh.read()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    req = urllib.request.Request(
        url_tpl.format(z=zoom, x=x, y=y),
        headers={"User-Agent": ua, "Accept": "image/png"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = resp.read()
    with open(path, "wb") as fh:
        fh.write(data)
    return data


def tile_grid(x0, y0, x1, y1, zoom):
    n = 2 ** zoom
    tx0 = max(0, int(math.floor(x0 / TILE)))
    ty0 = max(0, int(math.floor(y0 / TILE)))
    tx1 = min(n - 1, int(math.floor(x1 / TILE)))
    ty1 = min(n - 1, int(math.floor(y1 / TILE)))
    return tx0, ty0, tx1, ty1


def ring_path(points, zoom, ox, oy):
    cmds = []
    for i, (lon, lat) in enumerate(points):
        x, y = project(lon, lat, zoom)
        cmds.append(f"{'M' if i == 0 else 'L'}{x - ox:.2f},{y - oy:.2f}")
    return " ".join(cmds) + " Z"


def bbox_rect(bbox, zoom, ox, oy):
    lon0, lat0, lon1, lat1 = bbox
    xa, ya = project(lon0, lat1, zoom)
    xb, yb = project(lon1, lat0, zoom)
    return xa - ox, ya - oy, xb - xa, yb - ya


def build_svg(points, zoom, tx0, ty0, tx1, ty1, tiles, ox, oy, width, height, args):
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
        f'width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        f'<rect x="0" y="0" width="{width}" height="{height}" fill="#eef0f2"/>',
    ]
    for (x, y, data) in tiles:
        b64 = base64.b64encode(data).decode("ascii")
        px = x * TILE - ox
        py = y * TILE - oy
        parts.append(
            f'<image x="{px}" y="{py}" width="{TILE}" height="{TILE}" '
            f'xlink:href="data:image/png;base64,{b64}"/>'
        )
    if not args.no_bbox:
        bx, by, bw, bh = bbox_rect(PLAN_BBOX, zoom, ox, oy)
        parts.append(
            f'<rect x="{bx:.2f}" y="{by:.2f}" width="{bw:.2f}" height="{bh:.2f}" '
            'fill="none" stroke="#3b82f6" stroke-width="2.5" stroke-dasharray="8 6"/>'
        )
    parts.append(
        f'<path d="{ring_path(points, zoom, ox, oy)}" fill="rgba(245,158,11,0.18)" '
        'stroke="#f59e0b" stroke-width="2.5" stroke-linejoin="round"/>'
    )
    if not args.no_seeds:
        for lat, lon in SEEDS:
            sx, sy = project(lon, lat, zoom)
            parts.append(
                f'<circle cx="{sx - ox:.2f}" cy="{sy - oy:.2f}" r="4.5" '
                'fill="#ef4444" stroke="#ffffff" stroke-width="1.5"/>'
            )
    parts.append(
        f'<g font-family="sans-serif" font-size="16">'
        f'<rect x="12" y="12" width="430" height="62" rx="6" fill="rgba(17,24,39,0.82)"/>'
        f'<text x="24" y="36" fill="#f9fafb">valle_central.poly — {len(points)} points</text>'
        f'<text x="24" y="58" fill="#fbbf24" font-size="13">boundary amber · plan bbox blue dashed · seeds red</text>'
        f"</g>"
    )
    parts.append("</svg>")
    return "\n".join(parts)


def find_chromium():
    for name in ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable"):
        path = shutil.which(name)
        if path:
            return path
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--poly", default=os.path.join(ROOT, "regions", "valle_central.poly"))
    ap.add_argument("--out", default=os.path.join(ROOT, "data", "valle_central_boundary"))
    ap.add_argument("--basemap", choices=sorted(BASEMAPS) + ["none"], default="osm")
    ap.add_argument("--zoom", type=int, default=0)
    ap.add_argument("--min-zoom", type=int, default=8)
    ap.add_argument("--max-zoom", type=int, default=13)
    ap.add_argument("--max-px", type=int, default=2048)
    ap.add_argument("--pad", type=int, default=24)
    ap.add_argument("--cache", default=os.path.join(ROOT, "data", "tiles"))
    ap.add_argument("--no-bbox", action="store_true")
    ap.add_argument("--no-seeds", action="store_true")
    ap.add_argument("--svg-only", action="store_true")
    ap.add_argument(
        "--user-agent",
        default="ride-hailing-api dev boundary renderer (one-off; contact: repo owner)",
    )
    args = ap.parse_args()

    rings, points = parse_poly(args.poly)
    zoom = args.zoom or choose_zoom(points, args.max_px, args.pad, args.min_zoom, args.max_zoom)
    x0, y0, x1, y1 = pixel_bbox(points, zoom)
    x0 -= args.pad
    y0 -= args.pad
    x1 += args.pad
    y1 += args.pad
    tx0, ty0, tx1, ty1 = tile_grid(x0, y0, x1, y1, zoom)
    ox = tx0 * TILE
    oy = ty0 * TILE
    width = (tx1 - tx0 + 1) * TILE
    height = (ty1 - ty0 + 1) * TILE

    tiles = []
    if args.basemap != "none":
        url_tpl = BASEMAPS[args.basemap]
        total = (tx1 - tx0 + 1) * (ty1 - ty0 + 1)
        print(f"basemap={args.basemap} zoom={zoom} tiles={total} -> {args.cache}")
        for x in range(tx0, tx1 + 1):
            for y in range(ty0, ty1 + 1):
                try:
                    tiles.append((x, y, fetch_tile(url_tpl, zoom, x, y, args.cache, args.user_agent)))
                except Exception as exc:
                    print(f"  tile {zoom}/{x}/{y} failed: {exc}", file=sys.stderr)

    svg = build_svg(points, zoom, tx0, ty0, tx1, ty1, tiles, ox, oy, width, height, args)
    svg_path = args.out + ".svg"
    os.makedirs(os.path.dirname(svg_path), exist_ok=True)
    with open(svg_path, "w", encoding="utf-8") as fh:
        fh.write(svg)
    print(f"svg  {svg_path} ({width}x{height}, ring points={len(points)}, rings={rings})")

    if args.svg_only:
        return

    chromium = find_chromium()
    if not chromium:
        print("no chromium found; SVG written, rasterization skipped", file=sys.stderr)
        return

    png_path = args.out + ".png"
    cmd = [
        chromium,
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--hide-scrollbars",
        "--allow-file-access-from-files",
        "--force-device-scale-factor=1",
        f"--window-size={width},{height}",
        f"--screenshot={png_path}",
        "file://" + os.path.abspath(svg_path),
    ]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if not os.path.exists(png_path):
        sys.stderr.write(result.stderr[-2000:])
        raise SystemExit("chromium did not produce a screenshot")
    print(f"png  {png_path} ({os.path.getsize(png_path)} bytes)")


if __name__ == "__main__":
    main()
