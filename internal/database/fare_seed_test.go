package database

import (
	"math"
	"testing"
)

// TestGradeUpliftFactor pins the authoring-time derivation: a heavier class
// derives a larger per-(m/km) factor, the values match the documented energy
// model, and they round to the card column's 6 decimals so a re-seed is a no-op.
func TestGradeUpliftFactor(t *testing.T) {
	cases := []struct {
		vehicleType string
		want        float64
	}{
		{"sedan", 0.001377},
		{"suv", 0.001446},
		{"luxury", 0.000872},
	}
	seen := map[string]float64{}
	for _, tc := range cases {
		var class fareSeedClass
		for _, c := range fareSeedClasses {
			if c.vehicleType == tc.vehicleType {
				class = c
			}
		}
		got := gradeUpliftFactor(class)
		if got != tc.want {
			t.Errorf("%s gradeUpliftFactor = %v, want %v", tc.vehicleType, got, tc.want)
		}
		if got <= 0 {
			t.Errorf("%s factor = %v, a shipped default must be nonzero", tc.vehicleType, got)
		}
		seen[tc.vehicleType] = got
	}
	// An SUV (heavier, lower per-km tariff) must burn more per climb than a
	// sedan; the whole point of per-class knobs.
	if seen["suv"] <= seen["sedan"] {
		t.Errorf("suv factor %v <= sedan %v, want the heavier class to climb-cost more", seen["suv"], seen["sedan"])
	}
	// The cap is a product bound, not a derived value.
	if fareSeedGradeUpliftCap != 0.15 {
		t.Errorf("grade uplift cap = %v, want 0.15", fareSeedGradeUpliftCap)
	}
	// Derived factors must sit at or below the 6-decimal column resolution.
	for _, v := range seen {
		if math.Abs(v*1e6-math.Round(v*1e6)) > 1e-9 {
			t.Errorf("factor %v does not round to 6 decimals", v)
		}
	}
}
