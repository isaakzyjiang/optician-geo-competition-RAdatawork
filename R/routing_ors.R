# ---------------------------------------------------------------------------
# routing_ors.R
#
# Driving time between two points via openrouteservice (ORS), a free routing
# service run by HeiGIT (Heidelberg). Used to fill `drive_time_min` in T1.
#
# You need a free ORS API key (env var ORS_API_KEY, or the file ors_key.txt).
# run.R sources this file and only calls these functions when a key is present.
#
# The one idea that makes this cheap: a driving time depends only on the two
# endpoints, so we never route the same (customer PLZ, store PLZ) pair twice.
# We group the pairs by store and ask ORS for a 1-to-many "matrix" per store
# (one source = the store, many destinations = its customers' PLZ centroids).
# Results are cached to disk at the pair level, so re-running costs no quota
# and an interrupted run picks up where it left off.
#
# Needs: curl, jsonlite, data.table (all loaded by run.R).
# ---------------------------------------------------------------------------


# One ORS Matrix request: durations (seconds) from a single source to every
# destination. `coords` has columns lon, lat; row 1 is the source (store),
# the remaining rows are destinations (customers).
#
# ORS occasionally hiccups (rate limit, load balancer), so transient HTTP
# codes are retried with exponential backoff. A genuine client error (bad key,
# malformed request) is not retried -- we stop and show it.
ors_matrix_one <- function(coords, api_key,
                           profile   = "driving-car",
                           base_url  = "https://api.openrouteservice.org/v2/matrix/",
                           timeout   = 60,
                           max_retry = 4,
                           sleep_sec = 1.5,
                           verbose   = FALSE) {
  url    <- paste0(base_url, profile)
  n_dest <- nrow(coords) - 1L

  # ORS wants coordinates as [lon, lat]. sources/destinations are 0-indexed:
  # index 0 is the store, 1..n_dest are the customers.
  locations <- lapply(seq_len(nrow(coords)),
                      function(i) c(round(coords$lon[i], 6), round(coords$lat[i], 6)))
  body <- jsonlite::toJSON(
    list(locations    = locations,
         sources      = I(0L),                # I() keeps length-1 vectors as JSON arrays
         destinations = I(seq_len(n_dest)),
         metrics      = I("duration")),
    auto_unbox = TRUE, digits = 7)

  for (attempt in seq_len(max_retry)) {
    h <- curl::new_handle()
    curl::handle_setheaders(h,
      "Authorization" = api_key,
      "Content-Type"  = "application/json; charset=utf-8",
      "Accept"        = "application/json")
    curl::handle_setopt(h, post = TRUE, postfields = body,
                        timeout = timeout, connecttimeout = 20)

    resp <- tryCatch(curl::curl_fetch_memory(url, handle = h),
                     error = function(e) list(status_code = -1L,
                                              content = charToRaw(conditionMessage(e))))
    code <- resp$status_code
    text <- tryCatch(rawToChar(resp$content), error = function(e) "")

    if (identical(code, 200L)) {
      durations <- jsonlite::fromJSON(text)$durations   # 1 x n_dest matrix, seconds
      return(as.numeric(durations[1, ]))                # NA where a point is unreachable
    }

    transient <- code %in% c(429L, 500L, 502L, 503L, 504L, -1L)
    if (transient) {
      wait <- sleep_sec * 2^(attempt - 1)
      if (verbose) message(sprintf("  ORS %s -- retry %d/%d in %.1fs",
                                   code, attempt, max_retry, wait))
      Sys.sleep(wait)
      next
    }

    stop(sprintf("ORS Matrix failed (HTTP %s): %s", code, substr(text, 1, 300)))
  }

  warning(sprintf("ORS Matrix still failing after %d retries; returning NA", max_retry))
  rep(NA_real_, n_dest)
}


# Fill drive_time_min for a table of unique (customer, store) PLZ pairs.
#
#   pairs      data.table with columns `cust` and `store` (both PLZ codes)
#   centroids  data.table(plz, lon, lat)  -- the PLZ centroid lookup
#
# Returns `pairs` with a numeric `drive_time_min` column added.
compute_drive_time_ors <- function(pairs, centroids, api_key,
                                    cache_path       = NULL,
                                    max_dest_per_req = 1000L,  # ORS caps a matrix at 3500 routes
                                    sleep_sec        = 1.5,
                                    test_n_stores    = NULL,   # only route the first N stores
                                    verbose          = TRUE) {
  stopifnot(nzchar(api_key))

  pairs <- data.table::copy(data.table::as.data.table(pairs))
  pairs[, drive_time_min := NA_real_]

  # Resume: anything already in the cache is treated as done.
  if (!is.null(cache_path) && file.exists(cache_path)) {
    cache <- readRDS(cache_path)
    pairs[cache, on = .(cust, store), drive_time_min := i.drive_time_min]
    if (verbose) message(sprintf("[ORS] cache: %d of %d pairs already routed",
                                 pairs[!is.na(drive_time_min), .N], nrow(pairs)))
  }

  lookup <- data.table::as.data.table(centroids)
  data.table::setkey(lookup, plz)

  stores <- pairs[is.na(drive_time_min), unique(store)]
  if (!is.null(test_n_stores)) stores <- head(stores, test_n_stores)
  if (verbose) message(sprintf("[ORS] routing %d stores", length(stores)))

  for (s in seq_along(stores)) {
    store_id <- stores[s]
    rows     <- pairs[store == store_id & is.na(drive_time_min), which = TRUE]
    if (!length(rows)) next

    custs       <- pairs$cust[rows]
    store_coord <- lookup[store_id, .(lon, lat)]

    # Split a store's customers into chunks so no single request exceeds the cap.
    chunks <- split(seq_along(custs), ceiling(seq_along(custs) / max_dest_per_req))
    for (chunk in chunks) {
      coords  <- rbind(store_coord, lookup[custs[chunk], .(lon, lat)])
      seconds <- ors_matrix_one(coords, api_key, sleep_sec = sleep_sec, verbose = verbose)
      pairs$drive_time_min[rows[chunk]] <- seconds / 60
      Sys.sleep(sleep_sec)                       # stay polite / under the rate limit
    }

    # Persist after every store so an interruption never loses work.
    if (!is.null(cache_path)) {
      saveRDS(pairs[!is.na(drive_time_min), .(cust, store, drive_time_min)], cache_path)
    }
    if (verbose && (s %% 10 == 0 || s == length(stores)))
      message(sprintf("[ORS] %d/%d stores done", s, length(stores)))
  }

  pairs[]
}
