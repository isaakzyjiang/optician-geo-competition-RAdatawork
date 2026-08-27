# run.R -- build the distance and competition variables for the optician panel.
#
# HOW TO RUN: open this file, set the TWO paths in the "SETUP" block just below
# (DATA_FILE and PROJECT_DIR), then source the whole file. Nothing else needs
# editing to reproduce the shipped example. Use forward slashes "/" in paths on
# every OS, including Windows.
#
# It does three things, in order:
#   1. Clean the customer postcodes and run a health check       -> diagnostics.md
#   2. T1: straight-line distance and drive time per order        -> t1_distance.*
#   3. T2: opticians within a 20-minute drive per store, by year  -> competition_matrix.*
#
# Everything that varies between runs lives in the PARAMS list below -- paths,
# the example subset size, the API-key location. The as-shipped settings
# reproduce the 100-store example we hand over; the comments say what to change
# for a full run. Results go out as separate tables and are never merged into
# the raw transaction file, so the original data is left untouched.


# ===========================================================================
#  SETUP -- READ THIS FIRST.  Set the two paths below, then run the file.
#  Use forward slashes "/" in every path, even on Windows.
# ---------------------------------------------------------------------------
#  (1) DATA_FILE: full path to the raw data file you were given.
#      Windows example: "C:/Users/Anna/Desktop/OpticianDataSample.rda"
#      Mac example:     "/Users/anna/Desktop/OpticianDataSample.rda"
DATA_FILE   <- ""   # <-- put the path to OpticianDataSample.rda between the quotes
#
#  (2) PROJECT_DIR: the folder that contains THIS run.R file (it also holds the
#      data/ and output/ sub-folders). Leave "" to let the script find it
#      automatically; if it errors, set it by hand, e.g.
#      "C:/Users/Anna/Downloads/delivery"
PROJECT_DIR <- ""   # <-- usually leave empty; fill in only if asked to
# ===========================================================================

## --- resolve PROJECT_DIR (folder that holds run.R) and switch into it ------
## All the other paths in this script are relative to this folder, so we move
## into it once here; that is what makes the folder portable across machines.
if (!nzchar(PROJECT_DIR)) {
  PROJECT_DIR <- tryCatch({
    args <- commandArgs(FALSE)                       # Rscript run.R
    hit  <- grep("^--file=", args, value = TRUE)
    if (length(hit)) {
      dirname(normalizePath(sub("^--file=", "", hit[1]), mustWork = FALSE))
    } else if (requireNamespace("rstudioapi", quietly = TRUE) &&
               rstudioapi::isAvailable()) {          # RStudio "Source" button
      dirname(rstudioapi::getSourceEditorContext()$path)
    } else ""
  }, error = function(e) "")
}
if (!nzchar(PROJECT_DIR) || !file.exists(file.path(PROJECT_DIR, "run.R"))) {
  stop("Could not locate the project folder automatically. Set PROJECT_DIR at ",
       "the top of run.R to the folder that contains run.R (use forward slashes).")
}
setwd(PROJECT_DIR)

## --- resolve DATA_FILE ------------------------------------------------------
## If left blank, fall back to the original layout (data one level up); then
## check the file actually exists so the error is friendly, not cryptic.
if (!nzchar(DATA_FILE) && file.exists("../OpticianDataSample.rda")) {
  DATA_FILE <- "../OpticianDataSample.rda"
}
if (!nzchar(DATA_FILE) || !file.exists(DATA_FILE)) {
  stop("Raw data file not found. Set DATA_FILE at the top of run.R to the full ",
       "path of OpticianDataSample.rda (use forward slashes). Current value: '",
       DATA_FILE, "'")
}


# --- 0. Settings -----------------------------------------------------------
set.seed(20260717)                       # fixed, in case a later step needs randomness

PARAMS <- list(
  ## --- input data ---
  data_rda   = DATA_FILE,                     # raw transaction panel (.rda) -- set above
  data_obj   = "OpticianDataSample",          # object name inside the .rda

  ## --- PLZ reference (5-digit German postcode polygons) ---
  ## Source: suche-postleitzahl.org (OSM-derived, ODbL), mirrored on GitHub.
  ## See data/reference/SOURCE.md for full provenance & download date.
  plz_geojson = "data/reference/plz-5stellig.geojson",

  ## --- PLZ cleaning policy ---
  ## Explicit placeholder codes that are NOT real postcodes (data-entry fillers).
  ## 00000 dominates; the others are near-zero but caught defensively.
  plz_placeholders = c("00000", "99999", "11111", "12345", "00001", "98765"),

  ## Rows whose customer PLZ cannot be geolocated (placeholder/unmatched/invalid)
  ## are NOT dropped. T1 keeps every original row and fills the two distance
  ## columns with an obvious sentinel so they are visible at a glance (2026-07-19).
  unlocatable_sentinel = -999,

  ## Key used to link the standalone result tables back to the transactions.
  ## OrderNumber is unique per row in this data.
  join_key = "OrderNumber",

  ## --- T1 distance ---
  ## Metric CRS for area centroids: ETRS89 / UTM zone 32N (official DE, metres).
  plz_crs_metric    = 25832,
  out_centroids_rds = "output/plz_centroids.rds",   # cached PLZ centroid lookup

  ## --- Drive time via openrouteservice (ORS) ---
  ## Drive time needs a free ORS API key. We look for it in the env var
  ## ORS_API_KEY first, then in the file below. With no key, air_distance_km is
  ## still produced and drive_time_min is left as NA.
  ors_key_file         = "ors_key.txt",                 # gitignored; put your key here
  ors_cache_rds        = "output/drive_time_cache.rds", # pair-level cache; makes re-runs free
  ors_max_dest_per_req = 1000L,   # ORS caps a matrix at 3500 routes; stay well under
  ors_sleep_sec        = 1.5,     # pause between requests to respect the rate limit
  ## EXAMPLE vs FULL: 100 routes the first 100 stores (the handed-over demo).
  ## Set to NULL to route every store on a full run.
  ors_test_n_stores    = 100L,

  ## --- T2 yearly local competition ---
  ## Needs the ORS key (for the isochrones) and a live ohsome service.
  run_t2            = TRUE,
  t2_test_n_stores  = 100L,        # EXAMPLE: first 100 stores. NULL = all stores.
  t2_range_sec      = 1200,        # 20-minute drive isochrone
  ohsome_use_key    = TRUE,        # the HeiGIT account issues one key for ORS + ohsome
  t2_iso_cache      = "output/store_isochrones.rds",
  ## T2 delivered as a wide matrix: rows = year, columns = OpticianID,
  ## cell = competitors within 20-min drive (= opticians in isochrone - 1).
  t2_out_rds        = "output/competition_matrix.rds",
  t2_out_csv        = "output/competition_matrix.csv",

  ## --- outputs ---
  ## Results are delivered as STANDALONE tables, never merged into the raw
  ## transaction table (per RA instruction 2026-07-19).
  out_dir          = "output",
  out_diagnostics  = "output/diagnostics.md",
  out_validplz_rds = "output/plz_reference_valid.rds", # cached valid-PLZ vector
  out_t1_rds       = "output/t1_distance.rds",   # OrderNumber + 2 distance cols
  out_t1_csv       = "output/t1_distance.csv",
  write_csv        = TRUE
)

# --- 1. Packages and modules ----------------------------------------------
# jsonlite reads the geojson; data.table is the workhorse; sf computes polygon
# centroids; curl makes the API calls. Haversine is hand-coded, so we don't
# pull in geosphere just for one formula.
suppressWarnings(suppressMessages({
  library(jsonlite)
  library(data.table)
  library(sf)
  library(curl)
}))

# The API code lives in two small files. Sourcing them here just defines the
# functions; they only run later if there's a key / T2 is switched on.
source("R/routing_ors.R")      # drive time (ORS Matrix)
source("R/competition_t2.R")   # competition (ORS isochrones + ohsome)


# --- 2. Helper functions ---------------------------------------------------

# The reference geojson lists every real 5-digit German postcode. For the
# cleaning step we only need the codes themselves, not the polygons, so we pull
# out the `plz` property and cache the vector.
build_valid_plz <- function(geojson_path, cache_path = NULL) {
  if (!is.null(cache_path) && file.exists(cache_path)) {
    return(readRDS(cache_path))
  }
  gj <- jsonlite::fromJSON(geojson_path, simplifyVector = FALSE)
  plz <- vapply(gj$features, function(f) f$properties$plz, character(1))
  plz <- sort(unique(plz))
  stopifnot(all(nchar(plz) == 5L))        # sanity: reference is 5-digit
  if (!is.null(cache_path)) saveRDS(plz, cache_path)
  plz
}

# Rebuild the 5-digit postcode and judge whether we can trust it.
# CustomerZIPCode is stored as a number, so East-German codes have lost their
# leading zero -- sprintf("%05d") puts it back. The status tells the rest of the
# pipeline whether the code is usable:
#   valid       - a real postcode we have a polygon for  -> can compute distance
#   placeholder - a data-entry filler like 00000         -> unusable
#   unmatched   - looks real (its region exists) but we have no polygon for it
#   invalid     - the region itself is unknown; likely a typo or foreign code
classify_plz <- function(zip_numeric, valid_plz, placeholders) {
  zip5 <- sprintf("%05d", as.integer(zip_numeric))
  ref_pre3 <- unique(substr(valid_plz, 1L, 3L))

  status <- rep("valid", length(zip5))
  is_valid <- zip5 %in% valid_plz
  status[!is_valid] <- ifelse(
    zip5[!is_valid] %in% placeholders, "placeholder",
    ifelse(substr(zip5[!is_valid], 1L, 3L) %in% ref_pre3, "unmatched", "invalid")
  )
  data.table(zip5 = zip5, zip_status = status)
}

## --- T1 helpers -----------------------------------------------------------

## Geometric (area) centroid of every PLZ polygon, returned as lon/lat.
## Polygons are projected to a metric CRS (default ETRS89/UTM32N) BEFORE taking
## the centroid, then transformed back to WGS84 -- this yields a proper planar
## area centroid rather than a distorted lon/lat one. Cached to rds.
build_plz_centroids <- function(geojson_path, crs_metric = 25832, cache_path = NULL) {
  if (!is.null(cache_path) && file.exists(cache_path)) return(readRDS(cache_path))
  g   <- sf::st_read(geojson_path, quiet = TRUE)
  g   <- sf::st_transform(g, crs_metric)
  ctr <- sf::st_transform(sf::st_centroid(sf::st_geometry(g)), 4326)
  cc  <- sf::st_coordinates(ctr)
  dt  <- data.table(plz = g$plz, lon = cc[, 1], lat = cc[, 2])
  if (!is.null(cache_path)) saveRDS(dt, cache_path)
  dt
}

## Store location = modal customer PLZ among the store's (valid) orders.
## Ties broken deterministically by the smallest PLZ. Also returns diagnostics
## on how well-identified the location is (modal share, tie count).
compute_store_location <- function(dt) {
  dt[, {
    tb  <- sort(table(zip5), decreasing = TRUE)
    top <- names(tb)[tb == max(tb)]
    list(store_zip5        = min(top),                 # tie-break: smallest PLZ
         store_modal_n     = as.integer(max(tb)),
         store_n_orders    = .N,
         store_modal_share = as.numeric(max(tb) / sum(tb)),
         store_zip_tie     = length(top))
  }, by = OpticianID]
}

## Great-circle (Haversine) distance in km. Vectorised; scales to millions.
haversine_km <- function(lon1, lat1, lon2, lat2) {
  R <- 6371.0088; toR <- pi / 180
  dlat <- (lat2 - lat1) * toR; dlon <- (lon2 - lon1) * toR
  a <- sin(dlat / 2)^2 + cos(lat1 * toR) * cos(lat2 * toR) * sin(dlon / 2)^2
  2 * R * asin(pmin(1, sqrt(a)))
}

## Append a line to a growing character vector (tiny convenience for report).
`%+%` <- function(vec, line) c(vec, line)

# --- 3. Load the reference postcodes and the transaction data --------------
cat("[1/5] Loading reference PLZ ...\n")
valid_plz <- build_valid_plz(PARAMS$plz_geojson, PARAMS$out_validplz_rds)
cat("      reference valid PLZ:", length(valid_plz), "\n")

cat("[2/5] Loading raw transaction data ...\n")
e <- new.env()
load(PARAMS$data_rda, envir = e)
df <- as.data.table(get(PARAMS$data_obj, envir = e))
rm(e)
n_raw   <- nrow(df)
ncol_raw <- ncol(df)          # capture before we add scratch/feature columns
cat("      raw rows:", n_raw, "| cols:", ncol_raw, "\n")

# --- 4. Clean and classify the customer postcodes --------------------------
cat("[3/5] Cleaning & classifying customer PLZ ...\n")
df[, zip_raw := CustomerZIPCode]
cls <- classify_plz(df$zip_raw, valid_plz, PARAMS$plz_placeholders)
df[, `:=`(zip5 = cls$zip5, zip_status = cls$zip_status)]

## did leading-zero restoration matter? (raw stored with <5 digits)
df[, zip_raw_ndigit := nchar(as.character(as.integer(zip_raw)))]
df[, zip_leadzero_fixed := zip_raw_ndigit < 5L & zip_status == "valid"]

status_tab <- df[, .N, by = zip_status][order(-N)]

## ---- diagnostics: build report programmatically (reproducible) -----------
cat("[4/5] Writing diagnostics ...\n")
if (!dir.exists(PARAMS$out_dir)) dir.create(PARAMS$out_dir, recursive = TRUE)

pct <- function(x) sprintf("%.2f%%", 100 * x / n_raw)
R <- character(0)
R <- R %+% "# Diagnostics -- Slice 1: PLZ cleaning & data health check"
R <- R %+% ""
R <- R %+% paste0("_Generated by run.R on ", format(Sys.time(), "%Y-%m-%d %H:%M"), "._")
R <- R %+% ""
R <- R %+% "## 1. Input"
R <- R %+% paste0("- Raw file: `", PARAMS$data_rda, "` (object `", PARAMS$data_obj, "`)")
R <- R %+% paste0("- Rows: **", format(n_raw, big.mark = ","), "**, Columns: ", ncol_raw)
R <- R %+% paste0("- InvoiceYear range: ", min(df$InvoiceYear), "-", max(df$InvoiceYear))
R <- R %+% paste0("- Reference PLZ polygons: `", PARAMS$plz_geojson,
                  "` -> ", length(valid_plz), " valid 5-digit codes")
R <- R %+% ""
R <- R %+% "## 2. PLZ classification (all rows)"
R <- R %+% ""
R <- R %+% "| zip_status | meaning | rows | share |"
R <- R %+% "|---|---|---:|---:|"
meaning <- c(valid="in reference, has polygon (usable for distance)",
             placeholder="known filler code (00000, ...)",
             unmatched="valid format, Leitregion known, but no polygon",
             invalid="Leitregion unknown (typo/foreign/garbage)")
for (s in c("valid","placeholder","unmatched","invalid")) {
  nn <- status_tab[zip_status == s, N]; if (length(nn) == 0) nn <- 0L
  R <- R %+% paste0("| `", s, "` | ", meaning[[s]], " | ",
                    format(nn, big.mark=","), " | ", pct(nn), " |")
}
R <- R %+% ""
R <- R %+% paste0("**Leading-zero restoration** (raw stored with <5 digits, ",
                  "recovered to a valid PLZ via `sprintf(\"%05d\")`): **",
                  format(df[zip_leadzero_fixed == TRUE, .N], big.mark=","),
                  "** rows (mostly East-German 01xxx-09xxx).")
R <- R %+% ""

## unlocatable rows breakdown (kept, but sentinel in T1 output)
{
  drop_status <- c("placeholder","unmatched","invalid")
  dropped <- df[zip_status %in% drop_status]
  R <- R %+% "## 3. Unlocatable customer PLZ (kept; sentinel in T1 output)"
  R <- R %+% paste0("Rows with `zip_status` in {", paste(drop_status, collapse=", "),
                    "} cannot be geolocated. They are **not dropped**: the T1 table ",
                    "keeps them with the distance columns set to the sentinel `",
                    PARAMS$unlocatable_sentinel, "`. Total: **",
                    format(nrow(dropped), big.mark=","), "** (", pct(nrow(dropped)), ").")
  R <- R %+% ""
  R <- R %+% "### 3a. Unlocatable by year x status"
  byyr <- dcast(dropped[, .N, by=.(InvoiceYear, zip_status)],
                InvoiceYear ~ zip_status, value.var="N", fill=0L)
  hdr <- paste0("| InvoiceYear | ", paste(setdiff(names(byyr),"InvoiceYear"), collapse=" | "), " | total |")
  R <- R %+% hdr
  R <- R %+% paste0("|", paste(rep("---|", ncol(byyr)+1), collapse=""))
  scols <- setdiff(names(byyr), "InvoiceYear")
  for (i in seq_len(nrow(byyr))) {
    vals <- as.integer(byyr[i, ..scols])
    R <- R %+% paste0("| ", byyr$InvoiceYear[i], " | ",
                      paste(vals, collapse=" | "), " | ", sum(vals), " |")
  }
  R <- R %+% ""
  R <- R %+% "### 3b. Optician exposure"
  R <- R %+% paste0("- Distinct opticians with >=1 unlocatable row: **",
                    length(unique(dropped$OpticianID)), "** of ",
                    length(unique(df$OpticianID)))
  worst <- dropped[, .(dropped=.N), by=OpticianID][order(-dropped)][1:min(10,.N)]
  worst <- merge(worst, df[, .(total=.N), by=OpticianID], by="OpticianID")
  worst[, drop_share := sprintf("%.1f%%", 100*dropped/total)]
  worst <- worst[order(-dropped)]
  R <- R %+% ""
  R <- R %+% "Top 10 opticians by unlocatable-row count (sentinel in T1):"
  R <- R %+% ""
  R <- R %+% "| OpticianID | unlocatable | total | share |"
  R <- R %+% "|---:|---:|---:|---:|"
  for (i in seq_len(nrow(worst)))
    R <- R %+% paste0("| ", worst$OpticianID[i], " | ", worst$dropped[i],
                      " | ", worst$total[i], " | ", worst$drop_share[i], " |")
  R <- R %+% ""
  R <- R %+% "### 3c. Sample of `unmatched`/`invalid` codes (for manual review)"
  R <- R %+% ""
  R <- R %+% "Most frequent non-placeholder unlocatable codes:"
  R <- R %+% ""
  R <- R %+% "| zip5 | zip_status | rows |"
  R <- R %+% "|---|---|---:|"
  smp <- dropped[zip_status != "placeholder", .N, by=.(zip5, zip_status)][order(-N)][1:min(15,.N)]
  for (i in seq_len(nrow(smp)))
    R <- R %+% paste0("| ", smp$zip5[i], " | `", smp$zip_status[i], "` | ", smp$N[i], " |")
  R <- R %+% ""
}

R <- R %+% "## 4. Output"
n_keep <- df[zip_status == "valid", .N]
R <- R %+% paste0("- Locatable (`valid`) rows: **", format(n_keep, big.mark=","),
                  "** (", pct(n_keep), " of raw) get real distances; the rest get ",
                  "the sentinel `", PARAMS$unlocatable_sentinel, "`.")
R <- R %+% "- Results are delivered as standalone tables (see T1 section); the raw transaction table is left unchanged, nothing is merged into it."
R <- R %+% ""
R <- R %+% "## 5. Known limitations (carry into paper methods)"
R <- R %+% "- The reference polygon set (suche-postleitzahl.org, OSM-derived) contains ~8,173 PLZ, slightly fewer than the full German universe (~8,200). `unmatched` rows are likely real postcodes absent from the polygon set; no geometric centroid is available for them, so their T1 distances are set to the sentinel."
R <- R %+% "- PLZ is a numeric field with lost leading zeros; restored via zero-padding to 5 digits and validated against the reference."
R <- R %+% ""

writeLines(R, PARAMS$out_diagnostics)

## keep ALL rows; store location is computed from valid rows only (internal).
df[, c("zip_raw","zip_raw_ndigit") := NULL]
cat("[5/5] Slice-1 classification done (", n_keep, "valid /", n_raw, "rows ).\n")

# --- 5. T1: distance from each customer to their store ---------------------
# Everything here works at postcode resolution (that is as fine as the address
# data gets). A customer sits at the centroid of their PLZ; a store sits at the
# centroid of the PLZ most of its customers come from. air_distance_km is the
# straight-line (Haversine) distance between the two; drive_time_min is the ORS
# driving time. Since the distance only depends on the two postcodes, we compute
# it once per distinct (customer PLZ, store PLZ) pair and then attach it to every
# order. The result is a standalone table keyed by OrderNumber -- the raw data is
# never touched.
sent <- PARAMS$unlocatable_sentinel
df[, .rid := .I]                              # remember the original row order

cat("[T1 1/4] Building PLZ geometric centroids ...\n")
cent <- build_plz_centroids(PARAMS$plz_geojson, PARAMS$plz_crs_metric,
                            PARAMS$out_centroids_rds)

cat("[T1 2/4] Locating stores (modal customer PLZ, from valid rows) ...\n")
df_valid  <- df[zip_status == "valid"]
store_loc <- compute_store_location(df_valid)         # one store_zip5 per optician

cat("[T1 3/4] Computing air distance on unique PLZ pairs ...\n")
## unique (customer PLZ, store PLZ) pairs among VALID rows only
vp <- merge(df_valid[, .(OpticianID, cust = zip5)],
            store_loc[, .(OpticianID, store = store_zip5)], by = "OpticianID")
pairs <- unique(vp[, .(cust, store)])
pairs <- merge(pairs, cent[, .(cust  = plz, clon = lon, clat = lat)], by = "cust",  all.x = TRUE)
pairs <- merge(pairs, cent[, .(store = plz, slon = lon, slat = lat)], by = "store", all.x = TRUE)
pairs[, air_distance_km := haversine_km(clon, clat, slon, slat)]
n_pairs <- nrow(pairs)

## ---- T1b: drive_time_min via ORS (optional; needs ORS key) --------------
ors_key <- Sys.getenv("ORS_API_KEY")
if (!nzchar(ors_key) && file.exists(PARAMS$ors_key_file))
  ors_key <- trimws(readLines(PARAMS$ors_key_file, warn = FALSE)[1])
have_drive <- FALSE
if (nzchar(ors_key)) {
  cat("[T1b] Computing drive_time_min via openrouteservice ...\n")
  pd <- compute_drive_time_ors(
    pairs[, .(cust, store)], cent, ors_key,
    cache_path       = PARAMS$ors_cache_rds,
    max_dest_per_req = PARAMS$ors_max_dest_per_req,
    sleep_sec        = PARAMS$ors_sleep_sec,
    test_n_stores    = PARAMS$ors_test_n_stores)
  pairs <- merge(pairs, pd[, .(cust, store, drive_time_min)],
                 by = c("cust", "store"), all.x = TRUE)
  have_drive <- TRUE
} else if (file.exists(PARAMS$ors_cache_rds)) {
  # No key, but a drive-time cache is present (this is how the shipped example
  # reproduces without anyone needing a key). Use the cached values directly.
  cat("[T1b] No ORS key -> using cached drive times from", PARAMS$ors_cache_rds, "\n")
  cached <- readRDS(PARAMS$ors_cache_rds)
  pairs <- merge(pairs, cached[, .(cust, store, drive_time_min)],
                 by = c("cust", "store"), all.x = TRUE)
  have_drive <- TRUE
} else {
  cat("[T1b] No ORS key and no cache -> drive_time_min = NA for locatable rows",
      "(air_distance_km still produced).\n")
}

## ---- assemble STANDALONE T1 table: OrderNumber + the two distance cols ----
cat("[T1 4/4] Building standalone T1 table (all rows; sentinel for unlocatable) ...\n")
store_map <- store_loc[, .(OpticianID, store_zip5)]
t1 <- df[, .(.rid, OrderNumber, OpticianID, zip5, zip_status)]
t1 <- merge(t1, store_map, by = "OpticianID", all.x = TRUE)
dc <- c("cust", "store", "air_distance_km", if (have_drive) "drive_time_min")
t1 <- merge(t1, pairs[, ..dc],
            by.x = c("zip5", "store_zip5"), by.y = c("cust", "store"), all.x = TRUE)
if (!have_drive) t1[, drive_time_min := NA_real_]
## unlocatable rows (placeholder/unmatched/invalid) -> obvious sentinel
t1[zip_status != "valid", `:=`(air_distance_km = sent, drive_time_min = sent)]
setorder(t1, .rid)                            # restore original row order
stopifnot(nrow(t1) == n_raw)

t1_out <- t1[, .(OrderNumber, air_distance_km, drive_time_min)]
saveRDS(t1_out, PARAMS$out_t1_rds)
if (isTRUE(PARAMS$write_csv)) fwrite(t1_out, PARAMS$out_t1_csv)

## ---- T1 diagnostics ------------------------------------------------------
n_sent  <- t1[zip_status != "valid", .N]
n_valid <- t1[zip_status == "valid", .N]
D <- character(0)
D <- D %+% "" %+% "---" %+% "" %+% "# Diagnostics -- T1: air_distance_km & drive_time_min" %+% ""
D <- D %+% paste0("Standalone table `", PARAMS$out_t1_rds, "` / `.csv`: **",
                  format(n_raw, big.mark=","), "** rows (one per original order), ",
                  "columns `OrderNumber`, `air_distance_km`, `drive_time_min`. ",
                  "**Not merged** into the transaction table.")
D <- D %+% paste0("- Distances computed once on **", format(n_pairs, big.mark=","),
                  "** unique (customer PLZ, store PLZ) pairs, then attached by pair.")
D <- D %+% paste0("- Locatable rows: **", format(n_valid, big.mark=","), "**. ",
                  "Unlocatable rows set to sentinel `", sent, "`: **",
                  format(n_sent, big.mark=","), "** (", pct(n_sent), ").")
D <- D %+% ""
D <- D %+% "## Method"
D <- D %+% paste0("- Centroids: PLZ polygons projected to EPSG:", PARAMS$plz_crs_metric,
                  " (ETRS89/UTM32N), area centroid, back to WGS84.")
D <- D %+% "- Store location = centroid of the store's modal customer PLZ (ties -> smallest PLZ), from valid rows."
D <- D %+% "- `air_distance_km` = Haversine (Earth radius 6371.0088 km); `drive_time_min` = ORS Matrix (driving-car)."
D <- D %+% ""
D <- D %+% "## air_distance_km distribution over locatable rows (km)"
av <- t1[zip_status == "valid", air_distance_km]
qs <- round(quantile(av, c(0,.25,.5,.75,.9,.99,1), na.rm=TRUE), 2)
D <- D %+% "| min | p25 | median | p75 | p90 | p99 | max |"
D <- D %+% "|---:|---:|---:|---:|---:|---:|---:|"
D <- D %+% paste0("| ", paste(qs, collapse=" | "), " |")
D <- D %+% paste0("- `air_distance_km == 0` (customer in store's modal PLZ): **",
                  format(sum(av == 0, na.rm=TRUE), big.mark=","), "** of locatable (",
                  sprintf("%.1f%%", 100*sum(av==0,na.rm=TRUE)/n_valid),
                  ") -- accepted 0-pile-up.")
D <- D %+% ""
D <- D %+% "## Store-location identification (quality caveat)"
D <- D %+% paste0("- Stores: ", nrow(store_loc), " | modal-PLZ ties: ",
                  store_loc[store_zip_tie > 1, .N],
                  " | stores with modal_share < 0.10 (weak): ",
                  store_loc[store_modal_share < 0.10, .N])
D <- D %+% ""
if (have_drive) {
  D <- D %+% "## drive_time_min distribution over locatable rows (minutes)"
  dv <- t1[zip_status == "valid", drive_time_min]
  dq <- round(quantile(dv, c(0,.25,.5,.75,.9,.99,1), na.rm=TRUE), 1)
  D <- D %+% "| min | p25 | median | p75 | p90 | p99 | max |"
  D <- D %+% "|---:|---:|---:|---:|---:|---:|---:|"
  D <- D %+% paste0("| ", paste(dq, collapse=" | "), " |")
  n_drive <- t1[zip_status == "valid" & !is.na(drive_time_min), .N]
  D <- D %+% paste0("- Source: ORS Matrix (driving-car), retrieved ", format(Sys.Date()),
                    ". Drive time filled for **", format(n_drive, big.mark=","),
                    "** locatable orders; the rest are NA (stores outside the ",
                    if (is.null(PARAMS$ors_test_n_stores)) "run" else
                      paste0(PARAMS$ors_test_n_stores, "-store example"),
                    ", or ORS-unreachable).")
  D <- D %+% "- ORS uses the *current* road network (time-invariant approximation)."
  D <- D %+% ""
} else {
  D <- D %+% paste0("_`drive_time_min` is NA for locatable rows (no ORS key at run time); ",
                    "set the key and re-run to populate it._") %+% ""
}
cat(paste0(D, collapse = "\n"), file = PARAMS$out_diagnostics, append = TRUE)

# --- 6. T2: how many competitors each store faces, by year -----------------
# Draw a 20-minute drive isochrone around each store, then ask ohsome how many
# opticians sat inside it at each year's snapshot; subtract the store itself.
# The output is a wide matrix (rows = year, columns = OpticianID) written on its
# own -- again nothing is merged into the transactions. Runs only when run_t2 is
# on and a key is available (and it needs ohsome to be up).
have_t2 <- FALSE
# Runs with a key, or -- for the shipped example -- from the cached isochrones
# plus ohsome (ohsome itself needs no key).
iso_cached <- !is.null(PARAMS$t2_iso_cache) && file.exists(PARAMS$t2_iso_cache)
if (isTRUE(PARAMS$run_t2) && (nzchar(ors_key) || iso_cached)) {
  cat("[T2] Computing yearly local competition (isochrones + ohsome) ...\n")
  comp <- compute_competition_t2(
    store_loc, cent, ors_key,
    panel_years   = sort(unique(as.integer(df$InvoiceYear))),
    range_sec     = PARAMS$t2_range_sec,
    ohsome_key    = if (nzchar(ors_key) && isTRUE(PARAMS$ohsome_use_key)) ors_key else NULL,
    iso_cache     = PARAMS$t2_iso_cache,
    test_n_stores = PARAMS$t2_test_n_stores)
  ## reshape to the requested wide matrix: rows = Year, columns = OpticianID,
  ## cell = n_competitors_20min (opticians within 20-min drive, minus self).
  comp_mat <- dcast(comp, Year ~ OpticianID, value.var = "n_competitors_20min")
  setcolorder(comp_mat, c("Year", as.character(sort(unique(comp$OpticianID)))))
  setorder(comp_mat, Year)
  saveRDS(comp_mat, PARAMS$t2_out_rds)
  if (isTRUE(PARAMS$write_csv)) fwrite(comp_mat, PARAMS$t2_out_csv)
  have_t2 <- TRUE
  cat("[T2] competition matrix written:", nrow(comp_mat), "years x",
      ncol(comp_mat) - 1L, "opticians.\n")
} else if (isTRUE(PARAMS$run_t2)) {
  cat("[T2] run_t2=TRUE but no ORS key and no cached isochrones -> skipped.\n")
}

cat("\nDONE.",
    "\n  original rows :", n_raw, "(raw table untouched)",
    "\n  unique pairs  :", n_pairs,
    "\n  T1 sentinel   :", n_sent, "unlocatable rows set to", sent,
    "\n  drive_time    :", if (have_drive)
        paste0("computed (locatable NA: ", t1[zip_status=="valid" & is.na(drive_time_min), .N], ")")
      else "NA (no ORS key)",
    "\n  competition   :", if (have_t2) "written (T2 standalone)" else "skipped (run_t2=FALSE or no key)",
    "\n  T1 output     :", PARAMS$out_t1_rds,
    if (isTRUE(PARAMS$write_csv)) paste0(", ", PARAMS$out_t1_csv) else "",
    "\n  report        :", PARAMS$out_diagnostics, "\n")
