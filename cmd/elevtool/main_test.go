package main

import (
	"reflect"
	"testing"
)

// TestTilesForSJBBox is the regression test for the tile-list blocker: the
// fetch set must be derived from the VERTEX set, not the bbox corners. The SJ
// bbox corners span 3×2 tiles but only five receive vertices, and one of them
// (N08W084) holds a tiny 7-vertex cluster a bbox-derived set would miss while
// N08W085 holds zero and must be absent.
func TestTilesForSJBBox(t *testing.T) {
	// One vertex in each of the five live tiles, none in N08W085.
	verts := []vertex{
		{ID: 1, Lat: 8.999, Lng: -83.9}, // N08W084 (the tiny corner cluster)
		{ID: 2, Lat: 9.5, Lng: -84.5},   // N09W085
		{ID: 3, Lat: 9.5, Lng: -84.0},   // N09W084
		{ID: 4, Lat: 10.5, Lng: -84.5},  // N10W085
		{ID: 5, Lat: 10.5, Lng: -84.0},  // N10W084
	}
	got := sortedKeys(tilesFor(verts))
	want := []string{"N08W084", "N09W084", "N09W085", "N10W084", "N10W085"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("tilesFor(SJ vertices) = %v, want %v", got, want)
	}
}

// TestTilesForCornerCluster locks in that vertices straddling the -84 boundary
// resolve to their own tiles (floor semantics), not a bbox-derived set.
func TestTilesForCornerCluster(t *testing.T) {
	verts := []vertex{
		{ID: 1, Lat: 8.99, Lng: -83.99}, // N08W084 (the 7-vertex cluster, east of -84)
		{ID: 2, Lat: 9.00, Lng: -84.50}, // N09W085
		{ID: 3, Lat: 9.02, Lng: -84.40}, // N09W085 (still west of -84)
	}
	got := sortedKeys(tilesFor(verts))
	expected := []string{"N08W084", "N09W085"}
	if !reflect.DeepEqual(got, expected) {
		t.Errorf("tilesFor(corner cluster) = %v, want %v", got, expected)
	}
}

// TestTileNameForBoundary proves boundary coordinates go north/east (the
// northernmost/westernmost rows are handled by the Sample math, not the name).
func TestTileNameForBoundary(t *testing.T) {
	// lat exactly 10.0 goes into N10 (north), lng exactly -84.0 into W084 (east of -85 boundary).
	if got := tileNameFor(10.0, -84.0); got != "N10W084" {
		t.Errorf("tileNameFor(10.0,-84.0) = %q, want N10W084", got)
	}
	if got := tileNameFor(9.0, -85.0); got != "N09W085" {
		t.Errorf("tileNameFor(9.0,-85.0) = %q, want N09W085", got)
	}
}
