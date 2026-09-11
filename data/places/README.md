# Place names

`cities.tsv` — every city of 15 000 people or more (34 135 rows): name, latitude,
longitude, ISO country code; sorted by population. `countries.tsv` — ISO code →
country name. Both come from GeoNames (https://www.geonames.org, CC BY 4.0),
dump of 2026-09; regenerate with `cities15000.zip` and `countryInfo.txt` from
https://download.geonames.org/export/dump/.

Both files are compiled into the binary (`import()`); a photo with GPS gets the
nearest city within 100 km as its place. See `core/library/places.d`.
