# ---------------------------------------------------------------------------
# competition_t2.R
#
# T2 -- local competition each store faces, per year. For every store we count
# the other optician shops a customer could reach within a 20-minute drive, and
# we let that count vary year by year (this yearly variation is the whole point
# of the variable).
#
# Two free HeiGIT services do the heavy lifting, each for what it is built for:
#
#   1. openrouteservice (ORS) draws a 20-minute drive-time "isochrone" polygon
#      around each store. Roads change slowly, so we draw this once per store
#      and reuse it across years (a documented approximation).
#
#   2. ohsome answers historical questions about OpenStreetMap. We hand it the
#      isochrone polygons and ask, at each year's 1 November snapshot, how many
#      shop=optician are inside each one. ohsome does the spatial + temporal
#      counting on its side, so all the yearly movement comes from real OSM
#      history -- we don't approximate it.
#
#   competitors that year = (opticians inside the isochrone) - 1   [minus self]
#
# Snapshots are 1 Nov of 2007..2021. OSM history only goes back to Oct 2007, so
# 2001..2006 reuse the 2007 snapshot (see README/codebook for the caveat that
# early OSM coverage is thin and undercounts).
#
# Needs: curl, jsonlite, data.table (all loaded by run.R).
# ---------------------------------------------------------------------------


# Draw a 20-minute drive isochrone around each store.
#
#   stores  data.table(OpticianID, lon, lat)
#
# Returns a GeoJSON FeatureCollection (as a plain R list), one polygon per
# store, with the feature id set to the OpticianID so ohsome can group by it.
# Cached to disk -- isochrones are the same every run, so we never pay twice.
ors_isochrones <- function(stores, api_key,
                           range_sec  = 1200,               # 20 minutes
                           batch      = 5L,                 # ORS free tier: max 5 locations/request
                           base_url   = "https://api.openrouteservice.org/v2/isochrones/driving-car",
                           sleep_sec  = 1.5,
                           max_retry  = 4,
                           cache_path = NULL,
                           verbose    = TRUE) {
  if (!is.null(cache_path) && file.exists(cache_path)) return(readRDS(cache_path))
  stopifnot(nzchar(api_key))

  stores  <- data.table::as.data.table(stores)
  out     <- vector("list", nrow(stores))
  batches <- split(seq_len(nrow(stores)), ceiling(seq_len(nrow(stores)) / batch))

  for (b in seq_along(batches)) {
    idx  <- batches[[b]]
    locs <- lapply(idx, function(i) c(round(stores$lon[i], 6), round(stores$lat[i], 6)))
    body <- jsonlite::toJSON(
      list(locations = locs, range = I(range_sec), range_type = "time"),
      auto_unbox = TRUE, digits = 7)

    ok <- FALSE
    for (attempt in seq_len(max_retry)) {
      h <- curl::new_handle()
      # The isochrone endpoint returns GeoJSON and rejects Accept: application/json
      # with a 406 -- it insists on application/geo+json.
      curl::handle_setheaders(h,
        "Authorization" = api_key,
        "Content-Type"  = "application/json; charset=utf-8",
        "Accept"        = "application/geo+json; charset=utf-8")
      curl::handle_setopt(h, post = TRUE, postfields = body, timeout = 90)

      resp <- tryCatch(curl::curl_fetch_memory(base_url, handle = h),
                       error = function(e) list(status_code = -1L,
                                                content = charToRaw(conditionMessage(e))))
      if (identical(resp$status_code, 200L)) {
        fc <- jsonlite::fromJSON(rawToChar(resp$content), simplifyVector = FALSE)
        # ORS returns features in the same order we sent the locations.
        for (k in seq_along(idx)) {
          feature <- fc$features[[k]]
          feature$id             <- stores$OpticianID[idx[k]]
          feature$properties$id  <- stores$OpticianID[idx[k]]
          out[[idx[k]]] <- feature
        }
        ok <- TRUE
        break
      }
      if (resp$status_code %in% c(429L, 500L, 502L, 503L, 504L, -1L)) {
        Sys.sleep(sleep_sec * 2^(attempt - 1))
        next
      }
      stop(sprintf("ORS isochrone failed (HTTP %s): %s",
                   resp$status_code, substr(rawToChar(resp$content), 1, 300)))
    }
    if (!ok) stop("ORS isochrone: gave up after retries")

    Sys.sleep(sleep_sec)
    if (verbose && (b %% 10 == 0 || b == length(batches)))
      message(sprintf("[ORS iso] %d/%d batches", b, length(batches)))
  }

  fc <- list(type = "FeatureCollection", features = out)
  if (!is.null(cache_path)) saveRDS(fc, cache_path)
  fc
}


# Ask ohsome how many opticians sit inside each isochrone, at each yearly
# snapshot.
#
#   fc    the FeatureCollection from ors_isochrones() (feature ids = OpticianID)
#   time  an ISO-8601 interval, e.g. "2007-11-01/2021-11-01/P1Y" = every 1 Nov
#
# Returns data.table(OpticianID, year, n_opticians). The public ohsome API is
# free and normally keyless; we pass the HeiGIT key anyway since the account
# system now issues one. Boundaries are sent in batches, with 503 retries
# because ohsome occasionally goes briefly unavailable.
ohsome_count_by_boundary <- function(fc,
                                     filter    = "shop=optician",
                                     time      = "2007-11-01/2021-11-01/P1Y",
                                     api_key   = NULL,
                                     endpoint  = "https://api.ohsome.org/v1/elements/count/groupBy/boundary",
                                     batch     = 50L,
                                     sleep_sec = 1.0,
                                     max_retry = 5L,
                                     verbose   = TRUE) {
  features <- fc$features
  batches  <- split(seq_along(features), ceiling(seq_along(features) / batch))
  collected <- list()

  for (b in seq_along(batches)) {
    sub_fc <- list(type = "FeatureCollection", features = features[batches[[b]]])
    fields <- paste0("bpolys=", curl::curl_escape(jsonlite::toJSON(sub_fc, auto_unbox = TRUE, digits = 7)),
                     "&filter=", curl::curl_escape(filter),
                     "&time=",   curl::curl_escape(time),
                     "&format=json")

    parsed <- NULL
    for (attempt in seq_len(max_retry)) {
      h <- curl::new_handle()
      if (!is.null(api_key) && nzchar(api_key))
        curl::handle_setheaders(h, "Authorization" = api_key)
      curl::handle_setopt(h, post = TRUE, postfields = fields, timeout = 300)

      resp <- tryCatch(curl::curl_fetch_memory(endpoint, handle = h),
                       error = function(e) list(status_code = -1L,
                                                content = charToRaw(conditionMessage(e))))
      if (identical(resp$status_code, 200L)) {
        parsed <- jsonlite::fromJSON(rawToChar(resp$content))
        break
      }
      if (resp$status_code %in% c(429L, 500L, 502L, 503L, 504L, -1L)) {
        if (verbose) message(sprintf("[ohsome] batch %d HTTP %s -- retry %d/%d",
                                     b, resp$status_code, attempt, max_retry))
        Sys.sleep(sleep_sec * 2^(attempt - 1))
        next
      }
      stop(sprintf("ohsome failed (HTTP %s): %s",
                   resp$status_code, substr(rawToChar(resp$content), 1, 300)))
    }
    if (is.null(parsed)) stop("ohsome: gave up after retries (service down?)")

    # One groupByResult entry per boundary; each holds a result row per year.
    gb <- parsed$groupByResult
    for (i in seq_len(nrow(gb))) {
      res <- gb$result[[i]]
      collected[[length(collected) + 1]] <- data.table::data.table(
        OpticianID  = gb$groupByObject[i],
        year        = as.integer(substr(res$timestamp, 1, 4)),
        n_opticians = as.integer(res$value))
    }

    Sys.sleep(sleep_sec)
    if (verbose) message(sprintf("[ohsome] %d/%d boundary batches", b, length(batches)))
  }

  data.table::rbindlist(collected)
}


# Put the two services together and build the full (store, year) panel.
#
#   store_loc  data.table(OpticianID, store_zip5)  from run.R
#   cent       data.table(plz, lon, lat)           the PLZ centroid lookup
#
# Returns data.table(OpticianID, Year, n_opticians_20min, n_competitors_20min)
# for every year in `panel_years`, with pre-2007 years back-filled from 2007.
compute_competition_t2 <- function(store_loc, cent, api_key,
                                   panel_years   = 2001:2021,
                                   ohsome_start  = 2007L,
                                   range_sec     = 1200,
                                   ohsome_key    = NULL,
                                   iso_cache     = NULL,
                                   test_n_stores = NULL,   # only route the first N stores
                                   verbose       = TRUE) {
  # A key is only needed if we still have to draw isochrones; a cached run
  # (the shipped example) reproduces with no key -- ohsome needs none either.
  if (is.null(iso_cache) || !file.exists(iso_cache)) stopifnot(nzchar(api_key))

  # Each store sits at the centroid of its modal customer PLZ (from T1).
  store_xy <- merge(store_loc[, .(OpticianID, plz = store_zip5)],
                    cent[, .(plz, lon, lat)], by = "plz", all.x = TRUE)
  store_xy <- store_xy[!is.na(lon), .(OpticianID, lon, lat)]
  if (!is.null(test_n_stores)) store_xy <- head(store_xy, test_n_stores)

  if (verbose) message(sprintf("[T2] isochrones for %d stores", nrow(store_xy)))
  fc <- ors_isochrones(store_xy, api_key, range_sec = range_sec,
                       cache_path = iso_cache, verbose = verbose)

  last_year <- max(panel_years)
  interval  <- sprintf("%d-11-01/%d-11-01/P1Y", ohsome_start, last_year)
  if (verbose) message(sprintf("[T2] ohsome counts %s", interval))
  counts <- ohsome_count_by_boundary(fc, time = interval, api_key = ohsome_key,
                                     verbose = verbose)
  counts[, OpticianID := as.integer(OpticianID)]

  # Years before OSM history (pre-2007) reuse the 2007 count.
  base_2007 <- counts[year == ohsome_start, .(OpticianID, n_opticians)]
  early_years <- panel_years[panel_years < ohsome_start]
  early <- merge(CJ(OpticianID = base_2007$OpticianID, Year = early_years),
                 base_2007, by = "OpticianID")
  data.table::setnames(early, "n_opticians", "n_opticians_20min")

  late <- counts[year >= ohsome_start & year <= last_year,
                 .(OpticianID, Year = year, n_opticians_20min = n_opticians)]

  panel <- rbind(early, late)
  panel[, n_competitors_20min := pmax(n_opticians_20min - 1L, 0L)]  # drop self
  data.table::setkey(panel, OpticianID, Year)
  panel[]
}
