#!/usr/bin/env python3
"""Derive regions/valle_central.poly from the cached SRTMGL1 DEM.

The Central Valley is not a single-outlet watershed: it drains west through the
Tarcoles to the Pacific and east through the Reventazon to the Caribbean, split
by the Carpintera hills.  A one-outlet watershed is therefore wrong.  This
script implements the construct agreed for the routing region:

  1. low-relief valley floor mask V (slope / local relief / elevation / envelope)
  2. priority-flood sink fill + D8 flow routing
  3. catchment C = every cell whose D8 path reaches V (i.e. upstream of V)
  4. fill interior holes (mountains that drain outward stay inside)
  5. trace + simplify the largest component's outer ring

Everything is standard-library only (no numpy/scipy/GDAL/rasterio) and every
threshold is a CLI flag so drafts can be iterated cheaply.

Examples
--------
  # defaults, writes regions/valle_central.poly + report + GeoJSON
  python3 scripts/derive-valle-central-poly.py

  # fast coarse draft, no files written
  python3 scripts/derive-valle-central-poly.py --step 8 --dry-run

  # a tuned run (the first tuning direction when the draft is too generous)
  python3 scripts/derive-valle-central-poly.py \\
      --slope-max 8 --relief-max 100 --z-min 400 \\
      --out regions/valle_central.poly

  # diagnostics only (1 arcsec is slow: ~13M cells)
  python3 scripts/derive-valle-central-poly.py --step 1 --dry-run

Output is deterministic.  See data/valle_central_boundary_report.txt after a
run for parameters, component areas, boundary-drop statistics and warnings.
"""

import argparse
import gzip
import heapq
import math
import os
import sys
import time
from array import array
from collections import deque

VOID = -32768
EARTH_C = 111320.0      # metres per degree longitude at the equator
EARTH_C_LAT = 110540.0  # metres per degree latitude (mean)


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

def parse_bbox(text):
    parts = [float(p) for p in text.replace(" ", "").split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("bbox needs minLon,minLat,maxLon,maxLat")
    lon0, lat0, lon1, lat1 = parts
    if not (lon0 < lon1 and lat0 < lat1):
        raise argparse.ArgumentTypeError("bbox min values must be < max values")
    return (lon0, lat0, lon1, lat1)


def parse_seeds(text):
    """'lat,lon;lat,lon' -> [(lat, lon)]."""
    out = []
    for chunk in text.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        lat, lon = [float(p) for p in chunk.split(",")]
        out.append((lat, lon))
    if not out:
        raise argparse.ArgumentTypeError("at least one seed is required")
    return out


def parse_checkpoints(text):
    """'Name,lat,lon;Name,lat,lon' -> [(name, lat, lon)]."""
    out = []
    for chunk in text.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        bits = chunk.split(",")
        if len(bits) != 3:
            raise argparse.ArgumentTypeError(
                "checkpoints are Name,lat,lon; got %r" % chunk)
        out.append((bits[0].strip(), float(bits[1]), float(bits[2])))
    return out


def nameset(text):
    return {s.strip().lower() for s in text.split(",") if s.strip()}


# ---------------------------------------------------------------------------
# SRTM tiles / mosaic
# ---------------------------------------------------------------------------

def tile_name(lat, lon):
    """SRTM tile name whose SW corner is (floor(lat), floor(lon))."""
    la = int(math.floor(lat))
    lo = int(math.floor(lon))
    return "%c%02d%c%03d" % (
        "N" if la >= 0 else "S", abs(la),
        "E" if lo >= 0 else "W", abs(lo))


def load_tile(path, name):
    with gzip.open(path, "rb") as fh:
        raw = fh.read()
    n2 = len(raw) // 2
    n = int(round(math.sqrt(n2)))
    if n * n != n2 or n not in (1201, 3601):
        raise SystemExit(
            "%s: unexpected decompressed size %d bytes (want 1201^2 or 3601^2 "
            "int16 samples); a 404 body saved as .hgt.gz fails here" % (name, len(raw)))
    data = array("h")
    data.frombytes(raw)
    if sys.byteorder == "little":
        data.byteswap()
    return n, data


def mosaic(bbox, step, dem_dir, log):
    """Nearest-neighbour sample of the SRTM tiles onto a regular lon/lat grid.

    Grid convention: row 0 is SOUTH, column 0 is WEST.  lat = lat0 + i*d,
    lon = lon0 + j*d.  SRTM tiles themselves have row 0 = NORTH.
    """
    lon0, lat0, lon1, lat1 = bbox
    d = step / 3600.0
    nlon = int(round((lon1 - lon0) / d)) + 1
    nlat = int(round((lat1 - lat0) / d)) + 1

    lon_tile_max = int(math.floor(lon1 - 1e-9))
    lat_tile_max = int(math.floor(lat1 - 1e-9))
    needed = []
    for tla in range(int(math.floor(lat0)), lat_tile_max + 1):
        for tlo in range(int(math.floor(lon0)), lon_tile_max + 1):
            needed.append((tla, tlo))

    tiles = {}
    tile_info = []
    for tla, tlo in needed:
        name = tile_name(tla, tlo)
        path = os.path.join(dem_dir, name + ".hgt.gz")
        if not os.path.exists(path):
            log.append("WARNING missing tile %s (%s)" % (name, path))
            continue
        t0 = time.time()
        n, data = load_tile(path, name)
        tiles[(tla, tlo)] = (n, data)
        tile_info.append("%s (%d samples, %.1f MB gz, %.1fs)" % (
            name, n, os.path.getsize(path) / 1e6, time.time() - t0))

    if not tiles:
        raise SystemExit("no DEM tiles found in %s" % dem_dir)

    # per-column source tile + source column
    col_tile = []
    col_idx = []
    for j in range(nlon):
        lon = lon0 + j * d
        tlo = int(math.floor(lon))
        if tlo > lon_tile_max:
            tlo = lon_tile_max
        col_tile.append(tlo)
        col_idx.append(int(round((lon - tlo) * 3600.0)))

    z = array("f", [0.0]) * (nlat * nlon)
    void_cells = []
    for i in range(nlat):
        lat = lat0 + i * d
        tla = int(math.floor(lat))
        if tla > lat_tile_max:
            tla = lat_tile_max
        row = int(round((tla + 1.0 - lat) * 3600.0))
        row_tiles = [tiles.get((tla, tlo)) for tlo in col_tile]
        off = i * nlon
        for j in range(nlon):
            t = row_tiles[j]
            if t is None:
                z[off + j] = VOID
                void_cells.append(off + j)
                continue
            n, data = t
            v = data[row * n + col_idx[j]]
            if v == VOID:
                z[off + j] = VOID
                void_cells.append(off + j)
            else:
                z[off + j] = float(v)

    return {
        "nlat": nlat, "nlon": nlon, "d": d,
        "z": z, "void": void_cells, "tiles": tile_info,
        "lat0": lat0, "lon0": lon0,
    }


def fill_voids(grid):
    """Fill void cells from their nearest valid neighbour (BFS)."""
    z = grid["z"]
    nlon = grid["nlon"]
    nlat = grid["nlat"]
    voids = grid["void"]
    if not voids:
        return 0
    total = nlat * nlon
    filled = bytearray(total)
    dq = deque()
    for c in voids:
        for n in _neighbors(c, nlat, nlon):
            if z[n] != VOID:
                z[c] = z[n]
                filled[c] = 1
                dq.append(c)
                break
    while dq:
        c = dq.popleft()
        for n in _neighbors(c, nlat, nlon):
            if z[n] == VOID and not filled[n]:
                z[n] = z[c]
                filled[n] = 1
                dq.append(n)
    return len(voids)


# ---------------------------------------------------------------------------
# smoothing / slope / relief (analysis window only)
# ---------------------------------------------------------------------------

def box_mean(src, h, w, radius):
    """O(N) box mean with clamped edges."""
    if radius <= 0:
        return array("f", src)
    ww = w + 1
    integ = array("d", [0.0]) * ((h + 1) * (w + 1))
    for i in range(h):
        run = 0.0
        base = i * w
        up = i * ww
        cur = (i + 1) * ww
        for j in range(w):
            run += src[base + j]
            integ[cur + j + 1] = integ[up + j + 1] + run
    out = array("f", [0.0]) * (h * w)
    for i in range(h):
        i0 = i - radius
        i1 = i + radius
        if i0 < 0:
            i0 = 0
        if i1 >= h:
            i1 = h - 1
        r0 = i0 * ww
        r1 = (i1 + 1) * ww
        for j in range(w):
            j0 = j - radius
            j1 = j + radius
            if j0 < 0:
                j0 = 0
            if j1 >= w:
                j1 = w - 1
            s = (integ[r1 + j1 + 1] - integ[r1 + j0]
                 - integ[r0 + j1 + 1] + integ[r0 + j0])
            out[i * w + j] = s / ((i1 - i0 + 1) * (j1 - j0 + 1))
    return out


def median3(src, h, w):
    out = array("f", [0.0]) * (h * w)
    for i in range(h):
        i0 = i if i == 0 else i - 1
        i1 = i if i == h - 1 else i + 1
        for j in range(w):
            j0 = j if j == 0 else j - 1
            j1 = j if j == w - 1 else j + 1
            vals = []
            for ii in range(i0, i1 + 1):
                base = ii * w
                for jj in range(j0, j1 + 1):
                    vals.append(src[base + jj])
            vals.sort()
            out[i * w + j] = vals[len(vals) // 2]
    return out


def horn_slope(z, h, w, lat0, d):
    """Horn (1981) slope in degrees; edge rows/cols are left at 0."""
    out = array("f", [0.0]) * (h * w)
    for i in range(1, h - 1):
        lat = lat0 + i * d
        dx = EARTH_C * math.cos(math.radians(lat)) * d
        dy = EARTH_C_LAT * d
        b = i * w
        bn = (i - 1) * w
        bs = (i + 1) * w
        for j in range(1, w - 1):
            z1 = z[bn + j - 1]
            z2 = z[bn + j]
            z3 = z[bn + j + 1]
            z4 = z[b + j - 1]
            z6 = z[b + j + 1]
            z7 = z[bs + j - 1]
            z8 = z[bs + j]
            z9 = z[bs + j + 1]
            p = ((z3 + 2.0 * z6 + z9) - (z1 + 2.0 * z4 + z7)) / (8.0 * dx)
            q = ((z7 + 2.0 * z8 + z9) - (z1 + 2.0 * z2 + z3)) / (8.0 * dy)
            out[b + j] = math.degrees(math.atan(math.hypot(p, q)))
    return out


def sliding_max_rows(src, h, w, win):
    out = array("f", [0.0]) * (h * w)
    half = win // 2
    for i in range(h):
        base = i * w
        dq = deque()
        for j in range(w):
            v = src[base + j]
            while dq and src[base + dq[-1]] <= v:
                dq.pop()
            dq.append(j)
            lo = j - 2 * half
            while dq and dq[0] < lo:
                dq.popleft()
            out[base + j] = src[base + dq[0]]
    return out


def sliding_min_rows(src, h, w, win):
    out = array("f", [0.0]) * (h * w)
    half = win // 2
    for i in range(h):
        base = i * w
        dq = deque()
        for j in range(w):
            v = src[base + j]
            while dq and src[base + dq[-1]] >= v:
                dq.pop()
            dq.append(j)
            lo = j - 2 * half
            while dq and dq[0] < lo:
                dq.popleft()
            out[base + j] = src[base + dq[0]]
    return out


def sliding_max_cols(src, h, w, win):
    out = array("f", [0.0]) * (h * w)
    half = win // 2
    for j in range(w):
        dq = deque()
        for i in range(h):
            v = src[i * w + j]
            while dq and src[dq[-1] * w + j] <= v:
                dq.pop()
            dq.append(i)
            lo = i - 2 * half
            while dq and dq[0] < lo:
                dq.popleft()
            out[i * w + j] = src[dq[0] * w + j]
    return out


def sliding_min_cols(src, h, w, win):
    out = array("f", [0.0]) * (h * w)
    half = win // 2
    for j in range(w):
        dq = deque()
        for i in range(h):
            v = src[i * w + j]
            while dq and src[dq[-1] * w + j] >= v:
                dq.pop()
            dq.append(i)
            lo = i - 2 * half
            while dq and dq[0] < lo:
                dq.popleft()
            out[i * w + j] = src[dq[0] * w + j]
    return out


def local_relief(z, h, w, win, log):
    if win <= 1:
        return array("f", [0.0]) * (h * w)
    mx = sliding_max_cols(sliding_max_rows(z, h, w, win), h, w, win)
    mn = sliding_min_cols(sliding_min_rows(z, h, w, win), h, w, win)
    out = array("f", [0.0]) * (h * w)
    for k in range(h * w):
        out[k] = mx[k] - mn[k]
    return out


# ---------------------------------------------------------------------------
# valley floor mask and its components
# ---------------------------------------------------------------------------

def morph(mask, h, w, radius, dilate):
    if radius <= 0:
        return mask
    out = bytearray(h * w)
    for i in range(h):
        for j in range(w):
            v = 0
            if dilate:
                for ii in range(max(0, i - radius), min(h, i + radius + 1)):
                    base = ii * w
                    for jj in range(max(0, j - radius), min(w, j + radius + 1)):
                        if mask[base + jj]:
                            v = 1
                            break
                    if v:
                        break
            else:
                v = 1
                for ii in range(max(0, i - radius), min(h, i + radius + 1)):
                    base = ii * w
                    for jj in range(max(0, j - radius), min(w, j + radius + 1)):
                        if not mask[base + jj]:
                            v = 0
                            break
                    if not v:
                        break
            out[i * w + j] = v
    return out


def components(mask, h, w, offsets):
    """8-connected components; returns (label array, list of cell-index lists)."""
    labels = array("i", [-1]) * (h * w)
    comps = []
    for start in range(h * w):
        if not mask[start] or labels[start] >= 0:
            continue
        cid = len(comps)
        cells = [start]
        labels[start] = cid
        head = 0
        while head < len(cells):
            c = cells[head]
            head += 1
            for n in offsets(c):
                if mask[n] and labels[n] < 0:
                    labels[n] = cid
                    cells.append(n)
        comps.append(cells)
    return labels, comps


def build_v_mask(grid, env, args, log):
    """Compute V on the extended analysis window; returns local mask + stats."""
    z = grid["z"]
    nlat, nlon = grid["nlat"], grid["nlon"]
    lat0, lon0, d = grid["lat0"], grid["lon0"], grid["d"]

    pad = max(args.smooth, args.close, args.open, 2)
    cell_m = 0.5 * (EARTH_C * math.cos(math.radians(0.5 * (env[1] + env[3]))) * d
                    + EARTH_C_LAT * d)
    relief_cells = max(1, int(round(args.relief_window / cell_m)))
    if relief_cells % 2 == 0:
        relief_cells += 1
    relief_half = relief_cells // 2
    pad = max(pad, relief_half + 1)

    j_env0 = int(math.ceil((env[0] - lon0) / d))
    j_env1 = int(math.floor((env[2] - lon0) / d))
    i_env0 = int(math.ceil((env[1] - lat0) / d))
    i_env1 = int(math.floor((env[3] - lat0) / d))

    j0 = max(0, j_env0 - pad)
    j1 = min(nlon - 1, j_env1 + pad)
    i0 = max(0, i_env0 - pad)
    i1 = min(nlat - 1, i_env1 + pad)
    h = i1 - i0 + 1
    w = j1 - j0 + 1

    zsub = array("f", [0.0]) * (h * w)
    for i in range(h):
        src = (i0 + i) * nlon + j0
        dst = i * w
        zsub[dst:dst + w] = z[src:src + w]

    if args.smooth > 0:
        if args.smooth_mode == "median" and args.smooth == 1:
            sm = median3(zsub, h, w)
        else:
            if args.smooth_mode == "median":
                log.append("WARNING median smoothing only implemented for radius 1; "
                           "using mean for radius %d" % args.smooth)
            sm = box_mean(zsub, h, w, args.smooth)
        log.append("smoothed %dx%d window with %s radius %d" % (
            h, w, args.smooth_mode, args.smooth))
    else:
        sm = zsub

    slope = horn_slope(sm, h, w, lat0 + i0 * d, d)
    relief = local_relief(sm, h, w, relief_cells, log)

    mask = bytearray(h * w)
    for i in range(h):
        gi = i0 + i
        if gi < i_env0 or gi > i_env1:
            continue
        lat = lat0 + gi * d
        for j in range(w):
            gj = j0 + j
            if gj < j_env0 or gj > j_env1:
                continue
            k = i * w + j
            zz = zsub[k]
            if zz < args.z_min or zz > args.z_max:
                continue
            if slope[k] > args.slope_max:
                continue
            if relief[k] > args.relief_max:
                continue
            mask[k] = 1

    if args.close > 0:
        mask = morph(mask, h, w, args.close, True)
    if args.open > 0:
        mask = morph(mask, h, w, args.open, False)
    # closing/opening may have grown past the envelope: clip it back
    for i in range(h):
        gi = i0 + i
        for j in range(w):
            gj = j0 + j
            if gi < i_env0 or gi > i_env1 or gj < j_env0 or gj > j_env1:
                mask[i * w + j] = 0

    return {
        "mask": mask, "h": h, "w": w, "i0": i0, "j0": j0,
        "i_env0": i_env0, "i_env1": i_env1,
        "j_env0": j_env0, "j_env1": j_env1,
        "cell_m": cell_m, "relief_cells": relief_cells,
        "slope": slope, "relief": relief, "zsub": zsub,
    }


# ---------------------------------------------------------------------------
# hydrology
# ---------------------------------------------------------------------------

def priority_flood(z, nlat, nlon, log):
    """Priority-flood sink fill; every cell gets zf and a pop order."""
    total = nlat * nlon
    zf = array("f", z)
    order = array("i", [-1]) * total
    visited = bytearray(total)
    nbr_offsets = ((1, 0), (1, 1), (0, 1), (-1, 1),
                   (-1, 0), (-1, -1), (0, -1), (1, -1))
    heap = []
    ocean = 0
    for c in range(total):
        if z[c] <= 0.0:
            heapq.heappush(heap, (zf[c], c))
            ocean += 1
    if ocean == 0:
        log.append("WARNING no ocean cell (z <= 0) found in the DEM window; "
                   "seeding the window edge instead (divide may be truncated)")
        for j in range(nlon):
            c = j
            heapq.heappush(heap, (zf[c], c))
            c = (nlat - 1) * nlon + j
            heapq.heappush(heap, (zf[c], c))
        for i in range(nlat):
            c = i * nlon
            heapq.heappush(heap, (zf[c], c))
            c = i * nlon + nlon - 1
            heapq.heappush(heap, (zf[c], c))
    else:
        log.append("priority flood: seeded %d ocean cells (z <= 0)" % ocean)

    counter = 0
    while heap:
        zval, c = heapq.heappop(heap)
        if visited[c]:
            continue
        visited[c] = 1
        order[c] = counter
        counter += 1
        ci = c // nlon
        cj = c - ci * nlon
        for di, dj in nbr_offsets:
            ni = ci + di
            nj = cj + dj
            if ni < 0 or ni >= nlat or nj < 0 or nj >= nlon:
                continue
            n = ni * nlon + nj
            if visited[n]:
                continue
            if zval > zf[n]:
                zf[n] = zval
            heapq.heappush(heap, (zf[n], n))
    if counter != total:
        log.append("WARNING priority flood reached only %d/%d cells" % (counter, total))
    return zf, order


def distance_to_mask(mask, nlat, nlon):
    """BFS (8-neighbour) integer distance to the nearest mask cell."""
    total = nlat * nlon
    dist = array("i", [-1]) * total
    queue = array("i")
    for c in range(total):
        if mask[c]:
            dist[c] = 0
            queue.append(c)
    head = 0
    nbr_offsets = ((1, 0), (1, 1), (0, 1), (-1, 1),
                   (-1, 0), (-1, -1), (0, -1), (1, -1))
    while head < len(queue):
        c = queue[head]
        head += 1
        ci = c // nlon
        cj = c - ci * nlon
        nd = dist[c] + 1
        for di, dj in nbr_offsets:
            ni = ci + di
            nj = cj + dj
            if ni < 0 or ni >= nlat or nj < 0 or nj >= nlon:
                continue
            n = ni * nlon + nj
            if dist[n] < 0:
                dist[n] = nd
                queue.append(n)
    return dist


def d8_directions(zf, order, dist_v, vmask, nlat, nlon, d, lat0, log):
    """Steepest-descent D8 on the filled surface; flats tie-break toward V."""
    total = nlat * nlon
    down = array("i", [-1]) * total
    dirs = ((1, 0), (1, 1), (0, 1), (-1, 1),
            (-1, 0), (-1, -1), (0, -1), (1, -1))
    zero_flat = 0
    for i in range(nlat):
        lat = lat0 + i * d
        dx = EARTH_C * math.cos(math.radians(lat)) * d
        dy = EARTH_C_LAT * d
        dists = (dy, math.hypot(dx, dy), dx, math.hypot(dx, dy),
                 dy, math.hypot(dx, dy), dx, math.hypot(dx, dy))
        base = i * nlon
        for j in range(nlon):
            c = base + j
            if vmask[c]:
                continue
            zc = zf[c]
            best = -1
            best_score = 0.0
            # 1) steepest positive descent
            for k in range(8):
                di, dj = dirs[k]
                ni = i + di
                nj = j + dj
                if ni < 0 or ni >= nlat or nj < 0 or nj >= nlon:
                    continue
                n = ni * nlon + nj
                drop = zc - zf[n]
                if drop > 0.0:
                    score = drop / dists[k]
                    if score > best_score or (score == best_score and best >= 0
                                              and order[n] < order[best]):
                        best_score = score
                        best = n
            if best >= 0:
                down[c] = best
                continue
            # 2) flat: nearest V (BFS steps), then earliest flood order
            zero_flat += 1
            best_key = None
            for k in range(8):
                di, dj = dirs[k]
                ni = i + di
                nj = j + dj
                if ni < 0 or ni >= nlat or nj < 0 or nj >= nlon:
                    continue
                n = ni * nlon + nj
                dn = dist_v[n]
                if dn < 0:
                    dn = 1 << 30
                key = (dn, order[n])
                if best_key is None or key < best_key:
                    best_key = key
                    best = n
            if best >= 0:
                down[c] = best
    log.append("D8: %d flat/no-descent cells used the tie-break rule" % zero_flat)
    return down


def catchment(vmask, down, nlat, nlon, log):
    total = nlat * nlon
    inside = bytearray(total)
    stack = array("i")
    for c in range(total):
        if vmask[c]:
            inside[c] = 1
            stack.append(c)
    nbr_offsets = ((1, 0), (1, 1), (0, 1), (-1, 1),
                   (-1, 0), (-1, -1), (0, -1), (1, -1))
    head = 0
    while head < len(stack):
        c = stack[head]
        head += 1
        ci = c // nlon
        cj = c - ci * nlon
        for di, dj in nbr_offsets:
            ni = ci + di
            nj = cj + dj
            if ni < 0 or ni >= nlat or nj < 0 or nj >= nlon:
                continue
            n = ni * nlon + nj
            if not inside[n] and down[n] == c:
                inside[n] = 1
                stack.append(n)
    return inside


def fill_holes(inside, nlat, nlon, mode, min_hole_km2, cell_area_km2, log,
               lat0, lon0, d):
    """Flood non-C cells from the grid edge; unreached cells are holes."""
    total = nlat * nlon
    outside = bytearray(total)
    queue = array("i")
    for j in range(nlon):
        for c in (j, (nlat - 1) * nlon + j):
            if not inside[c] and not outside[c]:
                outside[c] = 1
                queue.append(c)
    for i in range(nlat):
        for c in (i * nlon, i * nlon + nlon - 1):
            if not inside[c] and not outside[c]:
                outside[c] = 1
                queue.append(c)
    head = 0
    while head < len(queue):
        c = queue[head]
        head += 1
        ci = c // nlon
        cj = c - ci * nlon
        for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ni = ci + di
            nj = cj + dj
            if ni < 0 or ni >= nlat or nj < 0 or nj >= nlon:
                continue
            n = ni * nlon + nj
            if not inside[n] and not outside[n]:
                outside[n] = 1
                queue.append(n)

    holes = [c for c in range(total) if not inside[c] and not outside[c]]
    if not holes:
        return inside, []
    # group holes into components for reporting / thresholding
    hmask = bytearray(total)
    for c in holes:
        hmask[c] = 1
    cid, hcomps = components(hmask, nlat, nlon,
                             lambda c: _neighbors(c, nlat, nlon))
    report = []
    fill_ids = set(range(len(hcomps)))
    if mode == "small":
        fill_ids = set()
        for cid_ in range(len(hcomps)):
            area = len(hcomps[cid_]) * cell_area_km2
            if area < min_hole_km2:
                fill_ids.add(cid_)
    for cid_ in range(len(hcomps)):
        cells = hcomps[cid_]
        area = len(cells) * cell_area_km2
        si = sum(c // nlon for c in cells) / len(cells)
        sj = sum(c % nlon for c in cells) / len(cells)
        report.append((cid_, len(cells), area, cid_ in fill_ids,
                       lon0 + sj * d, lat0 + si * d))
        if cid_ in fill_ids:
            for c in hcomps[cid_]:
                inside[c] = 1
    return inside, report


def _neighbors(c, nlat, nlon):
    ci = c // nlon
    cj = c - ci * nlon
    out = []
    for di, dj in ((1, 0), (1, 1), (0, 1), (-1, 1),
                   (-1, 0), (-1, -1), (0, -1), (1, -1)):
        ni = ci + di
        nj = cj + dj
        if 0 <= ni < nlat and 0 <= nj < nlon:
            out.append(ni * nlon + nj)
    return out


def largest_component(mask, nlat, nlon):
    total = nlat * nlon
    labels = array("i", [-1]) * total
    best_id = -1
    best_size = 0
    sizes = []
    for start in range(total):
        if not mask[start] or labels[start] >= 0:
            continue
        cid = len(sizes)
        count = 1
        labels[start] = cid
        stack = [start]
        head = 0
        while head < len(stack):
            c = stack[head]
            head += 1
            for n in _neighbors(c, nlat, nlon):
                if mask[n] and labels[n] < 0:
                    labels[n] = cid
                    stack.append(n)
                    count += 1
        sizes.append(count)
        if count > best_size:
            best_size = count
            best_id = cid
    if best_id < 0:
        return mask, [], 0
    out = bytearray(total)
    for c in range(total):
        if labels[c] == best_id:
            out[c] = 1
    return out, sizes, best_id


# ---------------------------------------------------------------------------
# boundary tracing (marching squares, 8-connected insides)
# ---------------------------------------------------------------------------

def trace_boundary(mask, nlat, nlon, lon0, lat0, d):
    """Return rings as lists of (lon, lat) in grid units (half-cell contour)."""
    segs = []  # ((u1,v1),(u2,v2)) integer half-grid coordinates
    for i in range(nlat - 1):
        for j in range(nlon - 1):
            a = mask[i * nlon + j]            # SW
            b = mask[i * nlon + j + 1]        # SE
            c = mask[(i + 1) * nlon + j + 1]  # NE
            dd = mask[(i + 1) * nlon + j]     # NW
            code = a | (b << 1) | (c << 2) | (dd << 3)
            if code in (0, 15):
                continue
            B = (2 * j + 1, 2 * i)
            R = (2 * j + 2, 2 * i + 1)
            T = (2 * j + 1, 2 * i + 2)
            L = (2 * j, 2 * i + 1)
            if code == 1:
                segs.append((L, B))
            elif code == 2:
                segs.append((B, R))
            elif code == 3:
                segs.append((L, R))
            elif code == 4:
                segs.append((R, T))
            elif code == 5:   # SW + NE inside: keep diagonal insides connected
                segs.append((B, R))
                segs.append((T, L))
            elif code == 6:
                segs.append((B, T))
            elif code == 7:
                segs.append((L, T))
            elif code == 8:
                segs.append((T, L))
            elif code == 9:
                segs.append((B, T))
            elif code == 10:  # SE + NW inside
                segs.append((L, B))
                segs.append((R, T))
            elif code == 11:
                segs.append((R, T))
            elif code == 12:
                segs.append((L, R))
            elif code == 13:
                segs.append((B, R))
            elif code == 14:
                segs.append((L, B))

    adj = {}
    for sid, (p, q) in enumerate(segs):
        adj.setdefault(p, []).append((sid, q))
        adj.setdefault(q, []).append((sid, p))

    used = bytearray(len(segs))
    rings = []
    for sid0 in range(len(segs)):
        if used[sid0]:
            continue
        p0, q0 = segs[sid0]
        used[sid0] = 1
        ring = [p0, q0]
        cur = q0
        while True:
            nxt = None
            for sid, other in adj[cur]:
                if not used[sid]:
                    nxt = (sid, other)
                    break
            if nxt is None:
                break
            used[nxt[0]] = 1
            cur = nxt[1]
            if cur == p0:
                break
            ring.append(cur)
        pts = [(lon0 + u * d * 0.5, lat0 + v * d * 0.5) for (u, v) in ring]
        rings.append(pts)
    return rings


def ring_area_m2(pts):
    if len(pts) < 3:
        return 0.0
    latm = 0.5 * (min(p[1] for p in pts) + max(p[1] for p in pts))
    kx = EARTH_C * math.cos(math.radians(latm))
    ky = EARTH_C_LAT
    s = 0.0
    for k in range(len(pts)):
        x1, y1 = pts[k][0] * kx, pts[k][1] * ky
        x2, y2 = pts[(k + 1) % len(pts)][0] * kx, pts[(k + 1) % len(pts)][1] * ky
        s += x1 * y2 - x2 * y1
    return abs(s) * 0.5


def simplify_ring(pts, tol_m, lat_ref):
    if len(pts) < 4 or tol_m <= 0:
        return pts
    kx = EARTH_C * math.cos(math.radians(lat_ref))
    ky = EARTH_C_LAT
    local = [((lon) * kx, (lat) * ky) for lon, lat in pts]
    # closed ring: append the first point so DP sees the closing segment
    closed = local + [local[0]]
    keep = bytearray(len(closed))
    keep[0] = keep[-1] = 1
    stack = [(0, len(closed) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        ax, ay = closed[a]
        bx, by = closed[b]
        dx, dy = bx - ax, by - ay
        den = dx * dx + dy * dy
        best_d = -1.0
        best_k = -1
        for k in range(a + 1, b):
            px, py = closed[k]
            if den == 0.0:
                dist = math.hypot(px - ax, py - ay)
            else:
                t = ((px - ax) * dx + (py - ay) * dy) / den
                t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
                dist = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if dist > best_d:
                best_d = dist
                best_k = k
        if best_d > tol_m:
            keep[best_k] = 1
            stack.append((a, best_k))
            stack.append((best_k, b))
    out = []
    for k in range(len(pts)):
        if keep[k]:
            out.append(pts[k])
    return out


def segments_intersect(p1, p2, p3, p4):
    def orient(a, b, c):
        v = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
        if v > 1e-15:
            return 1
        if v < -1e-15:
            return -1
        return 0

    def onseg(a, b, c):
        return (min(a[0], b[0]) - 1e-15 <= c[0] <= max(a[0], b[0]) + 1e-15
                and min(a[1], b[1]) - 1e-15 <= c[1] <= max(a[1], b[1]) + 1e-15)

    o1, o2, o3, o4 = orient(p1, p2, p3), orient(p1, p2, p4), \
                     orient(p3, p4, p1), orient(p3, p4, p2)
    if o1 != o2 and o3 != o4:
        return True
    if o1 == 0 and onseg(p1, p2, p3):
        return True
    if o2 == 0 and onseg(p1, p2, p4):
        return True
    if o3 == 0 and onseg(p3, p4, p1):
        return True
    if o4 == 0 and onseg(p3, p4, p2):
        return True
    return False


def ring_is_simple(pts):
    n = len(pts)
    if n < 3:
        return False
    for a in range(n):
        a2 = (a + 1) % n
        for b in range(a + 1, n):
            b2 = (b + 1) % n
            if a2 == b or b2 == a:
                continue
            if segments_intersect(pts[a], pts[a2], pts[b], pts[b2]):
                return False
    return True


def point_in_ring(lon, lat, pts):
    inside = False
    n = len(pts)
    j = n - 1
    for i in range(n):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if ((yi > lat) != (yj > lat)):
            xint = (xj - xi) * (lat - yi) / (yj - yi) + xi
            if lon < xint:
                inside = not inside
        j = i
    return inside


# ---------------------------------------------------------------------------
# writers
# ---------------------------------------------------------------------------

def write_poly(path, name, pts):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="ascii") as fh:
        fh.write(name + "\n")
        fh.write("1\n")
        for lon, lat in pts:
            fh.write("%.6f %.6f\n" % (lon, lat))
        fh.write("END\n")
        fh.write("END\n")


def write_geojson(path, name, pts):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    ring = [[round(lon, 6), round(lat, 6)] for lon, lat in pts]
    if ring[0] != ring[-1]:
        ring.append(ring[0])
    coords = ", ".join("[%s, %s]" % (repr(p[0]), repr(p[1])) for p in ring)
    with open(path, "w", encoding="ascii") as fh:
        fh.write('{"type":"FeatureCollection","features":[{"type":"Feature",'
                 '"properties":{"name":"%s"},"geometry":{"type":"Polygon",'
                 '"coordinates":[[%s]]}}]}\n' % (name, coords))


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Derive the Valle Central valley-floor catchment polygon "
                    "from cached SRTMGL1 .hgt.gz tiles (stdlib only).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  python3 scripts/derive-valle-central-poly.py
  python3 scripts/derive-valle-central-poly.py --step 8 --dry-run
  python3 scripts/derive-valle-central-poly.py --slope-max 8 --relief-max 100
  python3 scripts/derive-valle-central-poly.py --no-geojson

Iteration notes:
  * --envelope only constrains the VALLEY FLOOR mask; the catchment may
    extend past it into the surrounding mountains.
  * --step 1 is slow (~13M cells); 4 (~120 m) is the useful default.
  * The first things to loosen/tighten are --slope-max, --relief-max and
    --z-min; the second tier is --z-max and --seed-radius-km.
""")
    ap.add_argument("--dem-dir", default="data/dem")
    ap.add_argument("--out", default="regions/valle_central.poly")
    ap.add_argument("--report", default="data/valle_central_boundary_report.txt")
    ap.add_argument("--geojson", default="data/valle_central_draft.geojson")
    ap.add_argument("--name", default="valle_central")
    ap.add_argument("--bbox", type=parse_bbox, default=parse_bbox("-85,9,-83,11"),
                    help="DEM mosaic window minLon,minLat,maxLon,maxLat")
    ap.add_argument("--envelope",
                    type=parse_bbox, default=parse_bbox("-84.75,9.55,-83.72,10.45"),
                    help="valley-floor mask constraint minLon,minLat,maxLon,maxLat")
    ap.add_argument("--step", type=int, default=4,
                    help="output grid spacing in arcseconds (1-10; 1 is slow)")
    ap.add_argument("--slope-max", type=float, default=10.0,
                    help="max slope for valley floor, degrees")
    ap.add_argument("--relief-max", type=float, default=150.0,
                    help="max local relief for valley floor, metres")
    ap.add_argument("--relief-window", type=float, default=1000.0,
                    help="local-relief square side, metres")
    ap.add_argument("--z-min", type=float, default=400.0)
    ap.add_argument("--z-max", type=float, default=1700.0)
    ap.add_argument("--smooth", type=int, default=1,
                    help="pre-smoothing radius in cells (0 disables)")
    ap.add_argument("--smooth-mode", choices=("mean", "median"), default="mean")
    ap.add_argument("--close", type=int, default=1,
                    help="morphological closing radius in cells (0 disables)")
    ap.add_argument("--open", type=int, default=0,
                    help="morphological opening radius in cells (0 disables)")
    ap.add_argument("--seed-radius-km", type=float, default=35.0,
                    help="keep valley-floor components within this distance of a seed")
    ap.add_argument("--simplify", type=float, default=150.0,
                    help="Douglas-Peucker tolerance, metres (0 disables)")
    ap.add_argument("--min-hole-km2", type=float, default=10.0,
                    help="with --fill-holes small: fill holes below this area")
    ap.add_argument("--fill-holes", choices=("all", "small"), default="all",
                    help="fill all interior holes (default) or only small ones")
    ap.add_argument("--report-min-km2", type=float, default=1.0,
                    help="list components/holes at or above this area; smaller ones are aggregated")
    ap.add_argument("--seeds", type=parse_seeds,
                    default=parse_seeds("9.9325,-84.0796;10.0162,-84.2116;"
                                        "9.9981,-84.1165;9.8644,-83.9194;"
                                        "10.0875,-84.470;9.8383,-83.8656"),
                    help="lat,lon;... city seeds used to keep floor components")
    ap.add_argument("--check", type=parse_checkpoints,
                    default=parse_checkpoints(
                        "San Jose,9.9325,-84.0796;Alajuela,10.0162,-84.2116;"
                        "Heredia,9.9981,-84.1165;Cartago,9.8644,-83.9194;"
                        "San Ramon,10.0875,-84.470;Paraiso,9.8383,-83.8656;"
                        "Puntarenas,9.9763,-84.8384;Liberia,10.6346,-85.4407;"
                        "Turrialba,9.905,-83.680;Irazu,9.9794,-83.8525;"
                        "Poas,10.1978,-84.2331"),
                    help="Name,lat,lon;... point-in-polygon checks")
    ap.add_argument("--expect-inside", type=nameset,
                    default=nameset("San Jose,Alajuela,Heredia,Cartago,"
                                    "San Ramon,Paraiso,Irazu,Poas"))
    ap.add_argument("--expect-outside", type=nameset,
                    default=nameset("Puntarenas,Liberia,Turrialba"))
    ap.add_argument("--dry-run", action="store_true",
                    help="compute and print, write no files")
    ap.add_argument("--no-geojson", action="store_true")
    args = ap.parse_args(argv)

    if not 1 <= args.step <= 10:
        raise SystemExit("--step must be 1..10")
    if args.step == 1:
        print("WARNING: --step 1 is slow (~13M cells, expect several minutes)",
              file=sys.stderr)

    t_start = time.time()
    timings = {}
    log = []
    notes = []

    t0 = time.time()
    grid = mosaic(args.bbox, args.step, args.dem_dir, log)
    timings["mosaic"] = time.time() - t0
    nlat, nlon = grid["nlat"], grid["nlon"]
    lat0, lon0, d = grid["lat0"], grid["lon0"], grid["d"]
    total = nlat * nlon
    log.append("mosaic: %dx%d samples at %d arcsec (%.1f m N-S)" % (
        nlat, nlon, args.step, EARTH_C_LAT * d))

    t0 = time.time()
    void_count = fill_voids(grid)
    timings["void fill"] = time.time() - t0
    void_pct = 100.0 * void_count / total
    log.append("voids: %d cells (%.3f%%)" % (void_count, void_pct))
    if void_pct > 1.0:
        notes.append("void coverage is %.2f%% (>1%%); filled values are nearest-neighbour" % void_pct)

    t0 = time.time()
    vinfo = build_v_mask(grid, args.envelope, args, log)
    timings["V mask"] = time.time() - t0
    log.append("relief window %d cells (%.0f m side)" % (
        vinfo["relief_cells"], vinfo["relief_cells"] * vinfo["cell_m"]))

    h, w = vinfo["h"], vinfo["w"]
    local = vinfo["mask"]
    labels, comps = components(local, h, w,
                               lambda c: _local_neighbors(c, h, w))
    comp_areas = [len(c) * vinfo["cell_m"] ** 2 / 1e6 for c in comps]
    log.append("valley-floor V: %d components, %.1f km2 total, largest %.1f km2" % (
        len(comps), sum(comp_areas), max(comp_areas) if comp_areas else 0.0))

    # --- snap seeds to V, keep nearby components -------------------------
    v_cells = [c for c in range(h * w) if local[c]]
    seed_rows = []
    kept = set()
    for sidx, (slat, slon) in enumerate(args.seeds):
        si = (slat - lat0) / d - vinfo["i0"]
        sj = (slon - lon0) / d - vinfo["j0"]
        best = None
        best_m = None
        for c in v_cells:
            ci = c // w
            cj = c - ci * w
            dy = (vinfo["i0"] + ci) * d + lat0 - slat
            dx = (vinfo["j0"] + cj) * d + lon0 - slon
            kx = EARTH_C * math.cos(math.radians(slat))
            dist = math.hypot(dx * kx, dy * EARTH_C_LAT)
            if best_m is None or dist < best_m:
                best_m = dist
                best = c
        if best is None:
            seed_rows.append((sidx, slat, slon, None, None, False))
            notes.append("seed #%d (%.4f,%.4f) has no valley-floor cell" % (
                sidx + 1, slat, slon))
            continue
        if best_m > 5000.0:
            notes.append("seed #%d (%.4f,%.4f) snapped %.1f km from the nearest "
                         "valley-floor cell" % (sidx + 1, slat, slon, best_m / 1000.0))
        kept.add(labels[best])
        seed_rows.append((sidx, slat, slon, best // w, best % w, best_m))

    radius_m = args.seed_radius_km * 1000.0
    for cid, cells in enumerate(comps):
        if cid in kept:
            continue
        # component within seed_radius of any seed?
        near = False
        sample = cells[0::max(1, len(cells) // 200)]
        for sidx, (slat, slon) in enumerate(args.seeds):
            kx = EARTH_C * math.cos(math.radians(slat))
            for c in sample:
                ci = c // w
                cj = c - ci * w
                dy = (vinfo["i0"] + ci) * d + lat0 - slat
                dx = (vinfo["j0"] + cj) * d + lon0 - slon
                if math.hypot(dx * kx, dy * EARTH_C_LAT) <= radius_m:
                    near = True
                    break
            if near:
                break
        if near:
            kept.add(cid)

    vmask = bytearray(total)
    for cid in sorted(kept):
        for c in comps[cid]:
            ci = c // w
            cj = c - ci * w
            gi = vinfo["i0"] + ci
            gj = vinfo["j0"] + cj
            vmask[gi * nlon + gj] = 1

    v_count = sum(vmask)
    v_area = v_count * vinfo["cell_m"] ** 2 / 1e6
    log.append("kept %d/%d V components (%.1f km2); dropped %d small/far patches" % (
        len(kept), len(comps), v_area, len(comps) - len(kept)))

    # --- hydrology -------------------------------------------------------
    t0 = time.time()
    zf, order = priority_flood(grid["z"], nlat, nlon, log)
    timings["priority flood"] = time.time() - t0
    t0 = time.time()
    dist_v = distance_to_mask(vmask, nlat, nlon)
    timings["dist-to-V"] = time.time() - t0
    t0 = time.time()
    down = d8_directions(zf, order, dist_v, vmask, nlat, nlon, d, lat0, log)
    timings["D8"] = time.time() - t0
    t0 = time.time()
    cand = catchment(vmask, down, nlat, nlon, log)
    timings["upstream BFS"] = time.time() - t0

    def cell_area_km2(i):
        lat = lat0 + i * d
        return (EARTH_C * math.cos(math.radians(lat)) * d) * (EARTH_C_LAT * d) / 1e6

    mean_cell_km2 = cell_area_km2(nlat // 2)
    t0 = time.time()
    cand, hole_report = fill_holes(cand, nlat, nlon, args.fill_holes,
                                   args.min_hole_km2, mean_cell_km2, log,
                                   lat0, lon0, d)
    timings["hole fill"] = time.time() - t0
    log.append("hole fill: %d hole(s) found" % len(hole_report))
    small_holes = []
    for cid, ncells, area, did_fill, clon, clat in hole_report:
        if area >= args.report_min_km2:
            log.append("  hole %d: %d cells, %.1f km2 at %.3f,%.3f, %s" % (
                cid, ncells, area, clon, clat,
                "filled" if did_fill else "kept as hole"))
        else:
            small_holes.append((area, did_fill))
        if area > 200.0:
            notes.append("large interior hole (%.1f km2 near %.3f,%.3f) %s; verify "
                         "it should be inside the region" % (
                             area, clon, clat,
                             "filled" if did_fill else "left open"))
    if small_holes:
        log.append("  plus %d hole(s) < %g km2 (%.1f km2 total)" % (
            len(small_holes), args.report_min_km2, sum(a for a, _ in small_holes)))

    final_mask, c_sizes, best_id = largest_component(cand, nlat, nlon)
    if len(c_sizes) > 1:
        notes.append("catchment had %d disconnected components (%s cells); only the "
                     "largest was kept" % (len(c_sizes),
                                           ", ".join(str(s) for s in c_sizes)))
    # recompute cell count / area of the kept component
    c_count = 0
    area_km2 = 0.0
    e_min = 1e9
    e_max = -1e9
    e_sum = 0.0
    bbox_c = [1e9, 1e9, -1e9, -1e9]
    z = grid["z"]
    for i in range(nlat):
        lat = lat0 + i * d
        ca = cell_area_km2(i)
        base = i * nlon
        for j in range(nlon):
            c = base + j
            if not final_mask[c]:
                continue
            c_count += 1
            area_km2 += ca
            zz = z[c]
            if zz < e_min:
                e_min = zz
            if zz > e_max:
                e_max = zz
            e_sum += zz
            lon = lon0 + j * d
            if lon < bbox_c[0]:
                bbox_c[0] = lon
            if lat < bbox_c[1]:
                bbox_c[1] = lat
            if lon > bbox_c[2]:
                bbox_c[2] = lon
            if lat > bbox_c[3]:
                bbox_c[3] = lat
    e_mean = e_sum / c_count if c_count else 0.0
    if c_count == 0:
        raise SystemExit("catchment is empty; widen the valley-floor thresholds")

    # --- boundary drop statistics ---------------------------------------
    drops = []
    nbr4 = ((1, 0), (-1, 0), (0, 1), (0, -1))
    edge_touch = 0
    for i in range(nlat):
        base = i * nlon
        for j in range(nlon):
            c = base + j
            if not final_mask[c]:
                continue
            if i == 0 or i == nlat - 1 or j == 0 or j == nlon - 1:
                edge_touch += 1
            outside_min = None
            for di, dj in nbr4:
                ni, nj = i + di, j + dj
                if ni < 0 or ni >= nlat or nj < 0 or nj >= nlon:
                    continue
                n = ni * nlon + nj
                if not final_mask[n]:
                    zv = z[n]
                    if outside_min is None or zv < outside_min:
                        outside_min = zv
            if outside_min is not None:
                drops.append(z[c] - outside_min)
    drops.sort()
    if drops:
        n = len(drops)
        p10 = drops[int(0.10 * (n - 1))]
        med = drops[int(0.50 * (n - 1))]
        p90 = drops[int(0.90 * (n - 1))]
        low_saddles = sum(1 for v in drops if v < 50.0)
    else:
        p10 = med = p90 = 0.0
        low_saddles = 0

    # --- trace / simplify ------------------------------------------------
    t0 = time.time()
    rings = trace_boundary(final_mask, nlat, nlon, lon0, lat0, d)
    timings["boundary trace"] = time.time() - t0
    rings.sort(key=lambda r: -ring_area_m2(r))
    ring = rings[0]
    raw_vertices = len(ring)
    if len(rings) > 1:
        notes.append("boundary tracing produced %d rings; kept the largest" % len(rings))
    simple_raw = ring_is_simple(ring)
    ring = simplify_ring(ring, args.simplify, 0.5 * (bbox_c[1] + bbox_c[3]))
    simple = ring_is_simple(ring)
    if not simple:
        notes.append("simplified ring is SELF-INTERSECTING; increase --simplify or "
                     "reduce --close")
    # drop the repeated closing point if DP kept it
    if len(ring) > 1 and ring[0] == ring[-1]:
        ring = ring[:-1]
    poly_area_km2 = ring_area_m2(ring) / 1e6

    # --- control points --------------------------------------------------
    checks = []
    for name, lat, lon in args.check:
        inside = point_in_ring(lon, lat, ring)
        key = name.lower()
        if key in args.expect_inside:
            expect = "inside"
        elif key in args.expect_outside:
            expect = "outside"
        else:
            expect = "?"
        ok = "ok" if expect == "?" or expect == ("inside" if inside else "outside") else "MISMATCH"
        checks.append((name, lat, lon, inside, expect, ok))

    if c_count * cell_area_km2(nlat // 2) and not (1000.0 <= area_km2 <= 15000.0):
        notes.append("area %.0f km2 is outside the plausible 1,000-15,000 km2 range"
                     % area_km2)
    if edge_touch:
        notes.append("catchment touches the DEM window edge (%d cells); the outer "
                     "divide may be truncated" % edge_touch)
    if drops:
        notes.append("boundary drop is measured across one ~%.0f m cell, so an "
                     "ordinary divide shows only a small positive value; the <50 m "
                     "'saddle' count is a heuristic, not a pass inventory"
                     % vinfo["cell_m"])
    mismatches = [c[0] for c in checks if c[5] == "MISMATCH"]
    if mismatches:
        notes.append("control-point expectation mismatch: %s (adjust --expect-inside/"
                     "--expect-outside or the thresholds)" % ", ".join(mismatches))

    # --- report ----------------------------------------------------------
    lines = []
    lines.append("Valle Central valley-floor catchment — draft boundary report")
    lines.append("=" * 72)
    lines.append("generated: %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    lines.append("command: %s" % " ".join([sys.argv[0]] + (argv if argv is not None else sys.argv[1:])))
    lines.append("")
    lines.append("PARAMETERS")
    lines.append("  dem-dir            %s" % args.dem_dir)
    lines.append("  bbox (DEM)         %s" % (",".join(repr(v) for v in args.bbox)))
    lines.append("  envelope (floor)   %s" % (",".join(repr(v) for v in args.envelope)))
    lines.append("  step               %d arcsec (%.1f m N-S)" % (args.step, EARTH_C_LAT * d))
    lines.append("  slope-max          %g deg" % args.slope_max)
    lines.append("  relief-max         %g m over %g m" % (args.relief_max, args.relief_window))
    lines.append("  z range            %g .. %g m" % (args.z_min, args.z_max))
    lines.append("  smooth             radius %d (%s)" % (args.smooth, args.smooth_mode))
    lines.append("  morphology         close %d, open %d" % (args.close, args.open))
    lines.append("  seed-radius        %g km" % args.seed_radius_km)
    lines.append("  simplify           %g m" % args.simplify)
    lines.append("  fill-holes         %s (small threshold %g km2)" % (
        args.fill_holes, args.min_hole_km2))
    lines.append("  seeds              %s" % "; ".join(
        "%.4f,%.4f" % s for s in args.seeds))
    lines.append("")
    lines.append("DEM")
    for t in grid["tiles"]:
        lines.append("  tile %s" % t)
    lines.append("  grid %d rows x %d cols = %d samples" % (nlat, nlon, total))
    lines.append("  voids %d (%.3f%%) -> nearest-neighbour filled" % (void_count, void_pct))
    lines.append("")
    lines.append("VALLEY FLOOR V (before catchment)")
    lines.append("  components found: %d; kept %d; total kept area %.1f km2" % (
        len(comps), len(kept), v_area))
    small_kept = []
    dropped_big = []
    for cid, cells in enumerate(comps):
        if cid in kept:
            if comp_areas[cid] >= args.report_min_km2:
                lines.append("  comp %-3d kept   %7d cells  %8.1f km2" % (
                    cid, len(cells), comp_areas[cid]))
            else:
                small_kept.append(comp_areas[cid])
        elif comp_areas[cid] >= args.report_min_km2:
            dropped_big.append((cid, len(cells), comp_areas[cid]))
    if small_kept:
        lines.append("  plus %d kept patch(es) < %g km2 (%.1f km2 total)" % (
            len(small_kept), args.report_min_km2, sum(small_kept)))
    for cid, ncells, area in dropped_big:
        lines.append("  comp %-3d DROPPED %7d cells  %8.1f km2 (outside seed radius)" % (
            cid, ncells, area))
    for sidx, slat, slon, si, sj, dist_m in seed_rows:
        if dist_m is None:
            lines.append("  seed %d (%.4f, %.4f): NO valley-floor cell" % (
                sidx + 1, slat, slon))
        else:
            lines.append("  seed %d (%.4f, %.4f) -> cell row %d col %d, %.2f km away" % (
                sidx + 1, slat, slon, si, sj, dist_m / 1000.0))
    lines.append("")
    lines.append("CATCHMENT C")
    lines.append("  cells %d; area %.1f km2 (cell-count)" % (c_count, area_km2))
    lines.append("  bbox  lon %.5f .. %.5f  lat %.5f .. %.5f" % (
        bbox_c[0], bbox_c[2], bbox_c[1], bbox_c[3]))
    lines.append("  elevation min %.0f m, mean %.0f m, max %.0f m" % (e_min, e_mean, e_max))
    lines.append("  boundary cells with an outside neighbour: %d" % len(drops))
    lines.append("  drop z_in - z_out: p10 %.0f m, median %.0f m, p90 %.0f m" % (
        p10, med, p90))
    lines.append("  low-saddle boundary cells (drop < 50 m): %d" % low_saddles)
    lines.append("")
    lines.append("POLYGON")
    lines.append("  raw vertices %d (simple=%s), simplified %d (simple=%s)" % (
        raw_vertices, simple_raw, len(ring), simple))
    lines.append("  shoelace area %.1f km2" % poly_area_km2)
    lines.append("  output %s%s" % (args.out, " (dry-run: not written)" if args.dry_run else ""))
    lines.append("")
    lines.append("CONTROL POINTS")
    lines.append("  %-12s %-10s %-10s %-8s %-8s %s" % (
        "name", "lat", "lon", "inside", "expect", "status"))
    for name, lat, lon, inside, expect, ok in checks:
        lines.append("  %-12s %-10.4f %-10.4f %-8s %-8s %s" % (
            name, lat, lon, "yes" if inside else "no", expect, ok))
    lines.append("")
    lines.append("RUNTIME")
    for k, v in timings.items():
        lines.append("  %-16s %.1fs" % (k, v))
    lines.append("  total            %.1fs" % (time.time() - t_start))
    lines.append("")
    if notes:
        lines.append("WARNINGS / CAVEATS")
        for n in notes:
            lines.append("  - " + n)
        lines.append("")
    if log:
        lines.append("PHASE LOG")
        for n in log:
            lines.append("  - " + n)
    lines.append("")

    report = "\n".join(lines)
    if not args.dry_run:
        os.makedirs(os.path.dirname(os.path.abspath(args.report)), exist_ok=True)
        with open(args.report, "w", encoding="utf-8") as fh:
            fh.write(report)
        write_poly(args.out, args.name, ring)
        if args.geojson and not args.no_geojson:
            write_geojson(args.geojson, args.name, ring)
    print(report)
    return 0


def _local_neighbors(c, h, w):
    ci = c // w
    cj = c - ci * w
    out = []
    for di, dj in ((1, 0), (1, 1), (0, 1), (-1, 1),
                   (-1, 0), (-1, -1), (0, -1), (1, -1)):
        ni = ci + di
        nj = cj + dj
        if 0 <= ni < h and 0 <= nj < w:
            out.append(ni * w + nj)
    return out


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
