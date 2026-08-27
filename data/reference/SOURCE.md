# Reference data provenance — German PLZ 5-digit polygons

**File:** `plz-5stellig.geojson` (9,413,999 bytes, 8,173 features)

**What it is:** Polygons of all German 5-digit postcode areas (PLZ-Gebiete),
with per-feature properties `plz`, `note`, `qkm`, `einwohner`. Used in this
project to (1) validate reconstructed customer postcodes (Slice 1) and (2)
later compute PLZ geometric centroids for distances (T1).

**Origin:** suche-postleitzahl.org — derived from OpenStreetMap data,
licensed under the **Open Database License (ODbL)**.

**Downloaded from (mirror):**
`https://raw.githubusercontent.com/tdudek/de-plz-geojson/master/plz-5stellig.geojson`

**Download date:** 2026-07-17

**Why a mirror instead of the original host:** the original download host
`downloads.suche-postleitzahl.org` no longer resolves (NXDOMAIN as of
2026-07-17). The GitHub repository `tdudek/de-plz-geojson` mirrors the exact
suche-postleitzahl.org `plz-5stellig` dataset. The `plz` property was
verified: 8,173 unique codes, all 5 digits, range 01067–99998.

**Reproducibility note:** OSM/suche-postleitzahl data is periodically updated.
This snapshot (8,173 PLZ) is the version used for all results. To refresh,
re-download and re-run `run.R`; the valid-PLZ count and any drop rates may
shift slightly.

**Citation (for paper methods):**
> Postcode area boundaries: suche-postleitzahl.org (OpenStreetMap-derived,
> ODbL), 5-digit PLZ polygons, snapshot retrieved 2026-07-17.
