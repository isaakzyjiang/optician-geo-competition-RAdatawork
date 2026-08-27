# What is in this folder

A reproducible R pipeline that builds two location variables for the German
optician panel, plus a **100-store worked example** of the outputs. Start by
reading `README.md`, then run `run.R`.

This is the pipeline + an example, not the full results. `air_distance_km` is
computed for every order; the two API-backed pieces (`drive_time_min`, the T2
matrix) are filled for the first 100 stores.

This public repo commits **only the small aggregate example outputs** (the T2
`competition_matrix` and `diagnostics.md`). Everything derived from the private
transaction panel — the per-order T1 table and the location caches — is
`.gitignore`d and regenerated locally by `run.R` from your own copy of the raw
data. See the "committed?" columns below and `README.md` for how to run it.

## Files

### Read / run these
| file | what it is |
|---|---|
| `README.md` | how to run it, what the outputs mean, how to scale to a full run, data sources, caveats |
| `run.R` | the pipeline — the only file you run. Top section (`PARAMS`) holds every path and setting |
| `codebook.md` | precise definition of every output column: units, algorithm, source, limitations |
| `R/routing_ors.R` | helper: driving time from openrouteservice (used by run.R) |
| `R/competition_t2.R` | helper: 20-min isochrones + ohsome optician counts (used by run.R) |
| `renv.lock` | exact package versions (R 4.4.1; jsonlite, data.table, sf, curl + deps) for reproducing the environment |
| `.gitignore` | keeps the API key and R junk out of version control |

### The results (in `output/`)
| file | what it is | committed? |
|---|---|---|
| `competition_matrix.csv` / `.rds` | **T2 deliverable.** Wide matrix: first column `Year` (2001–2021), then one column per `OpticianID`. Each cell = opticians within a 20-min drive that year, minus the store itself. Example holds 100 store columns | ✅ example |
| `diagnostics.md` | data health check, regenerated on every run: postcode cleaning results, what was set to the sentinel and why, and the distance/drive-time/store-location distributions | ✅ example |
| `t1_distance.csv` / `.rds` | **T1 deliverable.** One row per order (250,000): `OrderNumber`, `air_distance_km`, `drive_time_min`. Join to the panel by `OrderNumber`. Unlocatable postcodes carry `-999`; `drive_time_min` is `NA` outside the 100-store example | ⬜ derived from private data — produced locally by `run.R`, not committed |

### Reference and caches (in `data/` and `output/`)
| file | what it is | committed? |
|---|---|---|
| `data/reference/SOURCE.md` | where the postcode file came from, its licence, and the download date — for citing in the paper | ✅ |
| `data/reference/plz-5stellig.geojson` | German 5-digit postcode polygons (OSM / suche-postleitzahl.org, ODbL). Used for centroids and postcode validation | ⬜ download from the mirror in `SOURCE.md` |
| `output/plz_centroids.rds`, `plz_reference_valid.rds` | cached postcode centroids / valid-code list, built from the geojson | ⬜ rebuilt by `run.R` |
| `output/drive_time_cache.rds`, `store_isochrones.rds` | cached driving times / 20-min isochrones for the example | ⬜ rebuilt by `run.R` (needs a key) |

## Not included

- **The raw data** (`OpticianDataSample.rda`) — `run.R` reads it from the parent
  folder (`../OpticianDataSample.rda`); change `PARAMS$data_rda` if it lives
  elsewhere.
- **The API key** — deliberately left out. Only needed to *extend* the example
  (more stores / a full run). Put your own key in `ors_key.txt`; see README.
