package model

type Place struct {
	ID       string  `db:"id" json:"id"`
	Name     string  `db:"name" json:"name"`
	Category string  `db:"category" json:"category"`
	Address  *string `db:"address" json:"address"`
	Lat      float64 `db:"lat" json:"lat"`
	Lng      float64 `db:"lng" json:"lng"`
}

type NearbyPlaceResult struct {
	Place
	DistanceM float64 `db:"distance_m" json:"distance_m"`
	Rank      float64 `db:"rank" json:"rank"`
}

type PlaceSeed struct {
	OSMType  string
	OSMID    int64
	Name     string
	Category string
	Address  *string
	Lat      float64
	Lng      float64
}
