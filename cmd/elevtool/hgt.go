// Package main implements elevtool, the DEM sampler that writes SRTM-class
// elevation onto the routing vertices (api_plans/[elevation]_dem_ingest_and_noise_control.md).
//
// This file is the SRTM ".hgt" reader: it is deliberately stdlib-only (gzip +
// encoding/binary), separable from the DB writer so it can be unit-tested with
// no database and no network.
package main

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"strings"
)

// voidSentinel is the int16 value SRTM uses for "no data" in a cell.
const voidSentinel int16 = -32768

// Tile is one 1-degree SRTMGL1 ("skadi") .hgt tile in memory. Row 0 is the
// NORTHERNMOST row and column 0 the westernmost — getting this backwards
// silently mirrors a city north<->south, which is the single most likely bug
// in this tool after the URL itself.
type Tile struct {
	MinLat, MinLng float64 // SW corner, degrees
	Rows, Cols     int
	Data           []int16
	Name           string // e.g. "N09W085" — recorded as elevation_source
}

// ParseHGT decompresses a gzipped .hgt payload and validates its dimensions.
// name determines the tile's SW corner (and thus its lat/lng axis); it must be
// of the form N|S{LL}E|W{LLL} where {LL} is the zero-padded degree value.
func ParseHGT(name string, gzipped []byte) (*Tile, error) {
	minLat, minLng, err := tileCorner(name)
	if err != nil {
		return nil, err
	}

	zr, err := gzip.NewReader(bytes.NewReader(gzipped))
	if err != nil {
		return nil, fmt.Errorf("decompress %s: %w", name, err)
	}
	raw, err := io.ReadAll(zr)
	rerr := zr.Close()
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", name, err)
	}
	if rerr != nil {
		return nil, fmt.Errorf("close gzip %s: %w", name, rerr)
	}

	// SRTM dimensions, from the DECOMPRESSED length: 1201 => 3-arcsec,
	// 3601 => 1-arcsec. Reject any other size explicitly rather than guessing.
	var rows int
	switch len(raw) {
	case 1201 * 1201 * 2:
		rows = 1201
	case 3601 * 3601 * 2:
		rows = 3601
	default:
		return nil, fmt.Errorf(
			"%s: unexpected decompressed size %d bytes (expected 1201²×2 or 3601²×2); "+
				"a 404'd tile saved under a .hgt.gz name produces a ~290-byte XML body "+
				"that fails exactly here — check the URL prefix", name, len(raw))
	}

	t := &Tile{MinLat: minLat, MinLng: minLng, Rows: rows, Cols: rows, Name: name}
	t.Data = make([]int16, len(raw)/2)
	if err := binary.Read(bytes.NewReader(raw), binary.BigEndian, t.Data); err != nil {
		return nil, fmt.Errorf("decode %s: %w", name, err)
	}
	return t, nil
}

// tileCorner parses an SRTM tile name ("N09W085", "S01E006") into its SW corner.
// The lat hemisphere letter and degree are required and validated; the skadi
// directory segment is DERIVED from the name, never parsed separately.
func tileCorner(name string) (minLat, minLng float64, err error) {
	if len(name) != 7 {
		return 0, 0, fmt.Errorf("tile name %q: want 7 chars like N09W085, S01E006", name)
	}
	latHemi := name[0]
	lngHemi := name[3]

	var latDeg, lngDeg int
	if _, err := fmt.Sscanf(name[1:3], "%02d", &latDeg); err != nil {
		return 0, 0, fmt.Errorf("tile name %q: bad lat degrees: %w", name, err)
	}
	if _, err := fmt.Sscanf(name[4:7], "%03d", &lngDeg); err != nil {
		return 0, 0, fmt.Errorf("tile name %q: bad lng degrees: %w", name, err)
	}
	switch latHemi {
	case 'N':
		minLat = float64(latDeg)
	case 'S':
		minLat = -float64(latDeg)
	default:
		return 0, 0, fmt.Errorf("tile name %q: lat hemisphere must be N or S (got %q)", name, latHemi)
	}
	switch lngHemi {
	case 'E':
		minLng = float64(lngDeg)
	case 'W':
		minLng = -float64(lngDeg)
	default:
		return 0, 0, fmt.Errorf("tile name %q: lng hemisphere must be E or W (got %q)", name, lngHemi)
	}
	return minLat, minLng, nil
}

// At returns the raw cell value at (row, col); false on void or out of bounds.
func (t *Tile) At(row, col int) (int16, bool) {
	if row < 0 || row >= t.Rows || col < 0 || col >= t.Cols {
		return 0, false
	}
	v := t.Data[row*t.Cols+col]
	if v == voidSentinel {
		return 0, false
	}
	return v, true
}

// Sample returns the bilinear-interpolated elevation (meters) at a geographic
// point. Any void neighbour in the 2×2 cell, or a point outside the tile,
// makes it return false — a void is never silently averaged into a real number.
func (t *Tile) Sample(lat, lng float64) (float64, bool) {
	rowF := (t.MinLat + 1 - lat) * float64(t.Rows-1)
	colF := (lng - t.MinLng) * float64(t.Cols-1)
	if rowF < 0 || rowF > float64(t.Rows-1) || colF < 0 || colF > float64(t.Cols-1) {
		return 0, false
	}
	r0 := int(rowF)
	c0 := int(colF)
	r1 := r0 + 1
	c1 := c0 + 1
	if r1 >= t.Rows || c1 >= t.Cols {
		// Point on the far (east/north) edge: clamp to the last cell.
		r1 = t.Rows - 1
		c1 = t.Cols - 1
		if r0 > r1 {
			r0 = r1
		}
		if c0 > c1 {
			c0 = c1
		}
	}
	v00, ok := t.At(r0, c0)
	if !ok {
		return 0, false
	}
	v01, ok := t.At(r0, c1)
	if !ok {
		return 0, false
	}
	v10, ok := t.At(r1, c0)
	if !ok {
		return 0, false
	}
	v11, ok := t.At(r1, c1)
	if !ok {
		return 0, false
	}
	dr := rowF - float64(r0)
	dc := colF - float64(c0)
	top := float64(v00)*(1-dc) + float64(v01)*dc
	bot := float64(v10)*(1-dc) + float64(v11)*dc
	return top*(1-dr) + bot*dr, true
}

// tileNameFor returns the SRTM skadi tile name containing a coordinate, as a
// pure function so tile-set selection is testable with no DB and no network.
//
// Naming: the tile number is the FLOOR of the coordinate in its hemisphere's
// direction. For W hemisphere the number is the western (more-negative) bound,
// so lng=-84.5 floors to -85 → W085 (spans [-85,-84)); the SJ metro at -84.08
// is likewise W085, west of the -84 boundary. floor (not truncation) matters
// only for the W and S hemispheres, where truncation would point one tile east
// or north.
func tileNameFor(lat, lng float64) string {
	latH := 'N'
	latBand := int(math.Floor(lat))
	if latBand < 0 {
		latH = 'S'
		latBand = -latBand
	}
	lngH := 'E'
	lngBand := int(math.Floor(lng))
	if lngBand < 0 {
		lngH = 'W'
		lngBand = -lngBand
	}
	return fmt.Sprintf("%c%02d%c%03d", latH, latBand, lngH, lngBand)
}

// skadiDir returns the bucket directory segment derived from the tile name —
// never parsed independently, so there is a single source of truth per tile.
func skadiDir(name string) string {
	return strings.ToUpper(name[0:3])
}
