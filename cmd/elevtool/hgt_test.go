package main

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"math"
	"testing"
)

func makeGzipped(t *testing.T, rows int, vals []int16) []byte {
	t.Helper()
	raw := make([]byte, len(vals)*2)
	if err := binary.Write(bytes.NewBuffer(raw[:0]), binary.BigEndian, vals); err != nil {
		t.Fatalf("binary.Write: %v", err)
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(raw); err != nil {
		t.Fatalf("gzip write: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("gzip close: %v", err)
	}
	return buf.Bytes()
}

func TestTileCornerParsing(t *testing.T) {
	cases := []struct {
		name           string
		minLat, minLng float64
	}{
		{"N09W085", 9, -85},
		{"S01E006", -1, 6},
		{"N00E000", 0, 0},
	}
	for _, c := range cases {
		lat, lng, err := tileCorner(c.name)
		if err != nil {
			t.Fatalf("tileCorner(%q): %v", c.name, err)
		}
		if lat != c.minLat || lng != c.minLng {
			t.Errorf("tileCorner(%q) = (%v,%v), want (%v,%v)", c.name, lat, lng, c.minLat, c.minLng)
		}
	}
}

func TestTileCornerRejectsBad(t *testing.T) {
	for _, name := range []string{"", "N9W085", "X09W085", "N09X085", "N09W08", "N09W0855"} {
		if _, _, err := tileCorner(name); err == nil {
			t.Errorf("tileCorner(%q): expected error, got none", name)
		}
	}
}

// TestParseHGTRejectsWrongSize proves a 404'd XML body saved under a .hgt.gz
// name fails the size check rather than being silently misread.
func TestParseHGTRejectsWrongSize(t *testing.T) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write([]byte("<Error><Code>NoSuchKey</Code></Error>")); err != nil {
		t.Fatalf("gzip write: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("gzip close: %v", err)
	}
	if _, err := ParseHGT("N09W085", buf.Bytes()); err == nil {
		t.Fatal("expected size-rejection error, got none")
	}
}

// TestSampleNorthUpRowOrder proves row 0 is the NORTHERNMOST row: a tile whose
// row 0 is 2000 and last row is 0 must sample the northern point as 2000.
func TestSampleNorthUpRowOrder(t *testing.T) {
	rows, cols := 3, 3
	vals := make([]int16, rows*cols)
	for r := 0; r < rows; r++ {
		for c := 0; c < cols; c++ {
			vals[r*cols+c] = int16((rows - 1 - r) * 1000) // row 0 (north) = 2000, row 2 (south) = 0
		}
	}
	tile := &Tile{MinLat: 9, MinLng: -85, Rows: rows, Cols: cols,
		Data: vals, Name: "N09W085"}
	// Northern point: lat = MinLat+1 = 10 (top edge) => rowF = 0 => row 0 = 2000.
	if v, ok := tile.Sample(10, -85); !ok || v != 2000 {
		t.Errorf("northern edge Sample = (%v,%v), want (2000,true)", v, ok)
	}
	// Southern point: lat = MinLat = 9 => rowF = Rows-1 = 2 => row 2 = 0.
	if v, ok := tile.Sample(9, -85); !ok || v != 0 {
		t.Errorf("southern edge Sample = (%v,%v), want (0,true)", v, ok)
	}
}

func TestSampleBilinear(t *testing.T) {
	// Cell centre of a uniform-value tile returns that value.
	tile := &Tile{MinLat: 9, MinLng: -85, Rows: 3, Cols: 3,
		Data: []int16{5, 5, 5, 5, 5, 5, 5, 5, 5}, Name: "N09W085"}
	if v, ok := tile.Sample(9.5, -84.5); !ok || v != 5 {
		t.Errorf("centre Sample = (%v,%v), want (5,true)", v, ok)
	}

	// Corner (exact post) returns that post's value.
	tile = &Tile{MinLat: 0, MinLng: 0, Rows: 3, Cols: 3,
		Data: []int16{0, 10, 20, 30, 40, 50, 60, 70, 80}, Name: "N00E000"}
	// lat=0,lng=0 is rowF=(1-0)*2=2, colF=0 → r0=2,c0=0 → val 60.
	if v, ok := tile.Sample(0, 0); !ok || v != 60 {
		t.Errorf("corner Sample = (%v,%v), want (60,true)", v, ok)
	}
}

func TestSampleVoidNeighbourNotOK(t *testing.T) {
	tile := &Tile{MinLat: 0, MinLng: 0, Rows: 3, Cols: 3,
		Data: []int16{0, 10, 20, voidSentinel, 40, 50, 60, 70, 80}, Name: "N00E000"}
	// Point whose 2×2 cell includes the void at (1,0).
	if _, ok := tile.Sample(0.4, 0.4); ok {
		t.Error("Sample with a void neighbour should return not-ok")
	}
}

func TestSampleOutsideNotOK(t *testing.T) {
	tile := &Tile{MinLat: 0, MinLng: 0, Rows: 3, Cols: 3,
		Data: make([]int16, 9), Name: "N00E000"}
	if _, ok := tile.Sample(-0.1, 0); ok {
		t.Error("Sample south of tile should return not-ok")
	}
	if _, ok := tile.Sample(0, 1.1); ok {
		t.Error("Sample east of tile should return not-ok")
	}
}

func TestTileNameFor(t *testing.T) {
	cases := []struct {
		lat, lng float64
		want     string
	}{
		{9.9, -84.5, "N09W085"},  // west half of the -84 boundary
		{9.9, -84.0, "N09W084"},  // east half
		{10.0, -84.0, "N10W084"}, // boundary goes north/east
		{-1.0, 6.0, "S01E006"},
		{0.0, 0.0, "N00E000"},
		{-0.5, -0.5, "S01W001"}, // floor, not truncation, in the S/W hemispheres
	}
	for _, c := range cases {
		if got := tileNameFor(c.lat, c.lng); got != c.want {
			t.Errorf("tileNameFor(%v,%v) = %q, want %q", c.lat, c.lng, got, c.want)
		}
	}
	// Sanity: the San José metro (9.93,-84.08) sits WEST of the -84 boundary, so
	// it is in N09W085, not N09W084.
	if got := tileNameFor(9.93, -84.08); got != "N09W085" {
		t.Errorf("SJ metro tileNameFor = %q, want N09W085", got)
	}
}

func TestSamplePrecision(t *testing.T) {
	// A 3601-row tile round-trips through ParseHGT. Build a 1201 (cheaper) tile
	// with a known gradient and check ParseHGT matches a direct Tile.
	rows := 1201
	vals := make([]int16, rows*rows)
	for r := 0; r < rows; r++ {
		for c := 0; c < rows; c++ {
			vals[r*rows+c] = int16(r + c)
		}
	}
	gz := makeGzipped(t, rows, vals)
	tile, err := ParseHGT("N09W085", gz)
	if err != nil {
		t.Fatalf("ParseHGT: %v", err)
	}
	if tile.Rows != rows || tile.Cols != rows {
		t.Fatalf("dims = %d×%d, want %d×%d", tile.Rows, tile.Cols, rows, rows)
	}
	if tile.MinLat != 9 || tile.MinLng != -85 {
		t.Fatalf("corner = (%v,%v), want (9,-85)", tile.MinLat, tile.MinLng)
	}
	// SW corner (lat=MinLat, lng=MinLng) → rowF=1200, colF=0 → val 1200.
	if v, ok := tile.Sample(9, -85); !ok || !almostEqual(v, 1200) {
		t.Errorf("SW corner = (%v,%v), want (~1200,true)", v, ok)
	}
}

func almostEqual(a, b float64) bool {
	return math.Abs(a-b) < 1e-6
}
