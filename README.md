# Optician panel — distance and local-competition variables

This is a small, self-contained R pipeline that builds two location-based
variables for the German optician transaction panel:

- **T1 — distance:** for every order, how far the customer is from their store,
  both as the crow flies (`air_distance_km`) and by car (`drive_time_min`).
- **T2 — local competition:** for every store and year, how many other opticians
  a customer could reach within a 20-minute drive.

**What is delivered here is the pipeline plus a worked example, not the full
results.** The scripts run end-to-end and are validated against live data; the
outputs in `output/` were produced for the **first 100 stores** so the whole
thing can be inspected without spending API budget or hours of runtime. Scaling
to every store (or to a larger raw file) is a one-line change, described below.

The free-of-charge variable, `air_distance_km`, is computed for **all** orders;
only the two API-backed pieces (`drive_time_min` and T2) are limited to the
100-store example.


## Running it

You need R (developed on 4.4.1) with `jsonlite`, `data.table`, `sf`, and `curl`.
`sf` relies on the system GDAL/GEOS/PROJ libraries (on Windows the CRAN binary
bundles them, so `install.packages("sf")` normally just works).

**Two files are not in this repo and must be supplied locally** (both are kept
out of version control on purpose):

1. The **raw data** — set `DATA_FILE` to your own copy (see below). Not shipped.
2. The **postcode reference** `data/reference/plz-5stellig.geojson` — download it
   from the mirror in [`data/reference/SOURCE.md`](data/reference/SOURCE.md) and
   drop it at that path before running.

Open `run.R` and set the two paths in the **SETUP** block at the top, then run
the whole file:

```r
DATA_FILE   <- "C:/Users/Anna/Desktop/OpticianDataSample.rda"  # your data file
PROJECT_DIR <- ""     # leave empty; it auto-detects. Fill in only if it errors.
```

Use forward slashes `/` in paths on **every** OS, including Windows (a single
backslash `\` will not work). `DATA_FILE` is the only thing you must set — put
the raw data file wherever you like; it does **not** have to sit next to this
folder. Everything else is self-contained: the script switches into
`PROJECT_DIR` itself and all its other paths are relative to it. Then:

```r
source("run.R")   # or click "Source" in RStudio
```

Everything else configurable sits in the `PARAMS` list just below the SETUP
block. As shipped, it reproduces the 100-store example.

### Drive time and T2 need a free key

`drive_time_min` and T2 call [openrouteservice](https://openrouteservice.org)
(routing) and [ohsome](https://ohsome.org) (OpenStreetMap history), both run by
HeiGIT and free. Get a key:

1. Sign up at openrouteservice.org / account.heigit.org and copy your API key.
2. Save it in `ors_key.txt` (one line — this file is gitignored and never
   shipped). On macOS, make sure it is **plain text**: TextEdit saves `.txt` as
   Rich Text by default, which will not parse — use *Format → Make Plain Text*.

Without a key the pipeline still runs and still produces `air_distance_km`;
`drive_time_min` is just left as `NA`.

### Going from the example to the full run

In `PARAMS`, set both subset limits to `NULL`:

```r
ors_test_n_stores = NULL,   # was 100L
t2_test_n_stores  = NULL,   # was 100L
```

The full run is roughly 400 routing requests plus a handful of ohsome calls —
comfortably inside the free daily quota (2,500 requests/day). Results are cached
(`drive_time_cache.rds`, `store_isochrones.rds`), so a re-run costs nothing and
an interrupted run resumes where it stopped.


## Outputs

Results are written as **standalone tables**; nothing is merged into the raw
transaction file. Link them back yourself with the keys below.

> **Note for this public repository.** The outputs are all *derived from a
> private transaction panel*, so this repo ships only the small, aggregate
> worked-example results — enough to see the pipeline works. The per-order T1
> table and the location caches are **not** committed (they are `.gitignore`d);
> `run.R` regenerates them locally from your own copy of the raw data.

| file | what it is | how to join | in this repo? |
|---|---|---|---|
| `output/competition_matrix.{rds,csv}` | wide matrix: rows = year, columns = `OpticianID`, cell = competitors within 20 min | look up by year (row) and store (column) | ✅ example (100 stores) |
| `output/diagnostics.md` | the data health check, regenerated every run | — | ✅ example |
| `output/t1_distance.{rds,csv}` | one row per order: `OrderNumber`, `air_distance_km`, `drive_time_min` | by `OrderNumber` | ⬜ produced locally by `run.R` |

**Sentinel value:** orders whose postcode cannot be located keep their row in
`t1_distance` but carry **`-999`** in both distance columns, so they stand out at
a glance. Never treat `-999` as a real distance or time. In `drive_time_min`,
`NA` means something different: the postcode is fine but the drive time was not
computed (no key, or that store was outside the example subset).

On a full local run the pipeline also writes several lookup/cache files to
`output/` (`plz_centroids.rds`, `plz_reference_valid.rds`, `drive_time_cache.rds`,
`store_isochrones.rds`) so repeated runs avoid redoing work. These are
`.gitignore`d and rebuilt automatically.

See `codebook.md` for the precise definition of each variable.


## How the variables are built (for the methods section)

- **Customer location** = the geometric centroid of the customer's postcode area
  polygon. This is postcode-level resolution, which is as precise as the address
  data allows. Orders where the customer is in the store's own modal postcode get
  a distance of exactly 0 (about 42% of orders) — this pile-up at zero is
  expected and left as-is.
- **Store location** = the centroid of the postcode most of the store's customers
  come from (its modal PLZ), pooled over all years. Ties go to the smaller
  postcode. A store that relocated over 2001–2021 still gets a single location;
  how tightly a store's location is identified is reported in `diagnostics.md`.
- **`air_distance_km`** = great-circle (Haversine) distance between the two
  centroids. Centroids are taken in the projected CRS EPSG:25832 (ETRS89 / UTM
  32N, the official German grid) and converted back to lon/lat.
- **`drive_time_min`** = openrouteservice driving time between the same two points.
- **T2 competition** = a 20-minute drive isochrone is drawn once per store, and
  ohsome counts `shop=optician` inside it at each year's **1 November** snapshot;
  the store itself is subtracted. Snapshots run 2007–2021; OSM history starts in
  October 2007, so **2001–2006 reuse the 2007 value**. Because OSM shop coverage
  in Germany only matured around 2012–2015, early-year counts are systematically
  low — control for it with year fixed effects and, as a robustness check, rerun
  on 2015 onward. The isochrone uses today's road network for every year (roads
  change slowly relative to shop turnover).


## Data sources

| what | where | licence |
|---|---|---|
| transactions | `../OpticianDataSample.rda` (250k-row sample) | — |
| postcode polygons | `data/reference/plz-5stellig.geojson` — suche-postleitzahl.org (OSM) | ODbL |
| routing | openrouteservice.org (HeiGIT) | free tier |
| OSM shop history | ohsome (HeiGIT) | free |

Provenance and download date for the postcode file are in
`data/reference/SOURCE.md`.


## Things worth knowing

- The sample covers **2001–2021** (the brief mentioned 2025; 2021 is partial).
  It has 411 stores and ~238k customers. The code scales, but a genuine full run
  should use the complete raw file.
- The postcode reference (~8,173 polygons) is slightly smaller than the full
  German set (~8,200), so a few real postcodes end up `unmatched` and get the
  sentinel. Details and counts are in `diagnostics.md`.
- Reproducibility: the RNG seed is fixed, the postcode reference is pinned and
  dated, and package versions are recorded in `renv.lock`.


## Files

```
project/
├── run.R                  the pipeline — start here
├── R/
│   ├── routing_ors.R      drive time via openrouteservice
│   └── competition_t2.R   competition via ORS isochrones + ohsome
├── README.md              this file
├── codebook.md            definition of every output column
├── renv.lock              pinned package versions
├── data/reference/        postcode polygons + provenance
└── output/                the 100-store example results + diagnostics
```
