package main

import (
	"reflect"
	"testing"
)

// TestTilesFor covers the tile-list derivation for the SJ import: the fetch set
// must be derived from the VERTEX set, not the bbox corners. The SJ bbox corners
// span 3×2 tiles but only five receive vertices, and one of them (N08W084) holds
// a tiny 7-vertex cluster a bbox-derived set would miss while N08W085 holds zero
// and must be absent. The corner-cluster case additionally locks in floor
// semantics for vertices straddling the -84 boundary.
//
// (Consolidated from TestTilesForSJBBox and TestTilesForCornerCluster; both are
// the same property over different vertex sets.)
func TestTilesFor(t *testing.T) {
	cases := []struct {
		name  string
		verts []vertex
		want  []string
	}{
		{
			name: "sj_bbox_vertex_derived_not_corner_derived",
			verts: []vertex{
				{ID: 1, Lat: 8.999, Lng: -83.9}, // N08W084 (the tiny corner cluster)
				{ID: 2, Lat: 9.5, Lng: -84.5},   // N09W085
				{ID: 3, Lat: 9.5, Lng: -84.0},   // N09W084
				{ID: 4, Lat: 10.5, Lng: -84.5},  // N10W085
				{ID: 5, Lat: 10.5, Lng: -84.0},  // N10W084
			},
			want: []string{"N08W084", "N09W084", "N09W085", "N10W084", "N10W085"},
		},
		{
			name: "corner_cluster_floor_semantics",
			verts: []vertex{
				{ID: 1, Lat: 8.99, Lng: -83.99}, // N08W084 (the 7-vertex cluster, east of -84)
				{ID: 2, Lat: 9.00, Lng: -84.50}, // N09W085
				{ID: 3, Lat: 9.02, Lng: -84.40}, // N09W085 (still west of -84)
			},
			want: []string{"N08W084", "N09W085"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := sortedKeys(tilesFor(tc.verts))
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("tilesFor() = %v, want %v", got, tc.want)
			}
		})
	}
}
