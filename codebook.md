# Codebook — derived variables

The pipeline delivers its results as **standalone tables**, keyed so they can be
linked back to the transactions by the user — **nothing is merged into the raw
transaction table** (RA instruction 2026-07-19). Original columns are documented
in the source data dictionary (not reproduced here).

**Delivered tables**

| file | grain | key | columns |
|---|---|---|---|
| `output/t1_distance.{rds,csv}` | one row per order (all 250k) | `OrderNumber` | `air_distance_km`, `drive_time_min` |
| `output/competition_matrix.{rds,csv}` | wide matrix | first col `Year` | one column per `OpticianID`; cell = competitors within 20-min drive |

To attach T1 to the panel: `merge(orders, t1_distance, by = "OrderNumber")`.
To read a T2 value: `competition_matrix` row = year, column = the OpticianID; the
cell is the competitor count for that store-year. (To attach to transactions,
melt it back to long first: `melt(competition_matrix, id.vars = "Year")`.)

**Sentinel:** rows whose customer PLZ cannot be geolocated
(`placeholder`/`unmatched`/`invalid`) are **kept** in `t1_distance` with both
distance columns set to **`-999`** — an obvious, at-a-glance marker. Never treat
`-999` as a real distance/time.

Status legend: ✅ produced for all orders · 🔹 produced for the 100-store example
(scale up by setting the subset limits in `PARAMS` to `NULL`).

> **This delivery is the pipeline + a 100-store example.** `air_distance_km` is
> computed for every order (it costs nothing); `drive_time_min` and the T2 matrix
> are filled for the first 100 stores only. Everything else about them is real.

---

## Slice 1 — PLZ cleaning (internal; feeds T1) ✅

`zip5` / `zip_status` / `zip_leadzero_fixed` are computed internally and drive the
sentinel logic and the diagnostics report; they are **not** written as columns on
any delivered table.

### `zip5`
- **Definition:** Customer postcode reconstructed as a 5-character string.
- **Unit:** string (5 chars, leading zeros preserved).
- **Algorithm:** `sprintf("%05d", as.integer(CustomerZIPCode))`. The raw
  `CustomerZIPCode` is stored numeric, so East-German codes (01xxx–09xxx) lose
  their leading zero; zero-padding restores them.
- **Source:** derived from raw `CustomerZIPCode`.
- **Limitations:** padding cannot recover a code that was corrupted beyond a
  lost leading zero; such rows fall into `zip_status = invalid`.

### `zip_status`
- **Definition:** Classification of the reconstructed postcode against the
  reference polygon set.
- **Unit:** factor-like string, one of:
  - `valid` — exists in the reference PLZ polygons; usable for distance/
    competition features.
  - `placeholder` — a known data-entry filler (00000, 99999, 11111, 12345,
    00001, 98765), not a real postcode.
  - `unmatched` — well-formed and its Leitregion (first 3 digits) exists in the
    reference, but the exact 5-digit code has no polygon. Likely a real
    postcode absent from the OSM-derived set.
  - `invalid` — Leitregion not present in the reference; likely a typo, foreign
    code, or garbage.
- **Algorithm:** membership test of `zip5` in the reference valid-PLZ set; see
  `classify_plz()` in `run.R`.
- **Source:** reference PLZ polygons (see `data/reference/SOURCE.md`).
- **Limitations:** the reference set (~8,173 PLZ) is slightly smaller than the
  full German universe (~8,200), so a small share of real postcodes are
  labelled `unmatched`.

### `zip_leadzero_fixed`
- **Definition:** Flag = TRUE if the raw postcode was stored with fewer than 5
  digits and zero-padding recovered a *valid* PLZ.
- **Unit:** logical.
- **Algorithm:** `nchar(as.integer(CustomerZIPCode)) < 5 & zip_status == "valid"`.
- **Source:** derived.
- **Use:** audit trail for the East-German leading-zero fix (24,590 rows in the
  current sample).

### Unlocatable rows (no drop)
- Rows with `zip_status ∈ {placeholder, unmatched, invalid}` are **kept**; in
  `t1_distance` their two columns are set to the sentinel `-999`. Reported in
  `output/diagnostics.md` (by year × status, by optician). In the 250k sample:
  9,126 rows (3.65%) unlocatable, 240,874 locatable.

---

## Table `t1_distance` — distance per order

Keyed by `OrderNumber`; one row per original order (250k). Exactly two result
columns. Store location is an internal method detail (modal customer PLZ centroid,
ties → smallest PLZ, pooled over all years), not exported.

### `air_distance_km` ✅
- **Definition:** Great-circle (Haversine) distance between the customer PLZ
  geometric centroid and the store PLZ geometric centroid.
- **Unit:** kilometres (Earth radius 6371.0088 km); `-999` = unlocatable PLZ.
- **Algorithm:** (1) each PLZ polygon projected to EPSG:25832 (ETRS89/UTM32N),
  area centroid, back to WGS84; (2) store location = centroid of the store's
  *modal* customer PLZ; (3) Haversine. Computed once per unique (customer PLZ,
  store PLZ) pair (21,846 in the sample) and attached by pair.
- **Source:** reference PLZ polygons (`data/reference/SOURCE.md`) + transactions.
- **Limitations:** PLZ-level resolution; same-PLZ orders get exactly 0 (41.8% —
  accepted 0-pile-up); store location quality varies (25/411 stores have modal
  share < 0.10, flagged in diagnostics); a store that relocated is still one PLZ.

### `drive_time_min` 🔹 (example: first 100 stores; NA elsewhere)
- **Definition:** Driving time in minutes (`driving-car`) between the customer
  and store PLZ centroids.
- **Unit:** minutes; `-999` = unlocatable PLZ; `NA` = locatable but not computed
  (no key at run time) or ORS-unreachable.
- **Algorithm:** openrouteservice (ORS) Matrix API, one request per store
  (1 source × N customer destinations), same unique pairs as `air_distance_km`,
  cached at pair level. See `R/routing_ors.R`.
- **Source:** openrouteservice.org (HeiGIT, OSM, free tier). Key in `ors_key.txt`
  or env `ORS_API_KEY`. Live-validated (HTTP 200).
- **Limitations:** ORS uses the *current* road network (time-invariant approximation).

---

## Table `competition_matrix` — T2 🔹 (example: first 100 stores)

**Wide matrix**: first column `Year` (one row per year, 2001–2021), then one
column per `OpticianID`. Each cell = **competitors within a 20-minute drive** for
that store in that year = (opticians in the store's 20-min isochrone) − 1
(excludes the store itself; floored at 0). The example holds 100 store columns;
set `t2_test_n_stores = NULL` for all stores. Standalone; not merged.

**Cell value — construction**
- **Isochrone:** ORS Isochrones → one 20-min `driving-car` polygon per store
  (today's road network, treated as time-invariant).
- **Count:** the polygon is sent to ohsome `count/groupBy/boundary` as `bpolys`,
  which counts `shop=optician` inside it at each 11-01 snapshot server-side; then
  minus 1 for self. See `R/competition_t2.R`.
- **Snapshots:** 11-01 of 2007–2021; **2001–2006 back-filled with the 2007-11-01
  value** (ohsome history starts ~2007-10).
- **Source:** ORS + ohsome (HeiGIT, OSM, free). **Unit:** count.
- **Limitations:** (a) OSM shop coverage in Germany matured ~2012–2015, so early
  years may undercount competitors (single-directional, year-correlated) — use
  year FE and a ≥2015 robustness subsample; (b) isochrone uses the current road
  network for all years; (c) store location is the modal-PLZ centroid (see T1).
