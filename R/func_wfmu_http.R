# Shared constants and HTTP helpers for scraping wfmu.org.
# Source this file before any of the other func_*.R scraping helpers.

wfmu_root <- "https://www.wfmu.org"
base_url <- paste0(wfmu_root, "/playlists")

# Seconds to wait between requests so we don't hammer the site.
pause <- 0.5

ua <- httr::user_agent(
  "wfmu-comment-counter/1.0 (contact: aspteinmetz@yahoo.com)"
)

# Matches dates such as "September 3, 2026" or "Sept. 3, 2026".
date_pattern <- "\\b(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\\.?\\s+\\d{1,2},\\s+\\d{4}\\b"

# Fetch a URL and parse it as HTML. Returns NULL on any network/HTTP/parse
# failure so callers can treat "page unavailable" as a normal outcome.
safe_get_html <- function(url) {
  Sys.sleep(pause)
  res <- tryCatch(
    httr::GET(url, ua, httr::timeout(30)),
    error = function(e) NULL
  )
  if (is.null(res) || httr::http_error(res)) {
    return(NULL)
  }
  tryCatch(xml2::read_html(res), error = function(e) NULL)
}

# Normalise a scraped playlist href to the show_id format stored in the cache:
# "/playlists/shows/168921" -> "shows/168921". Legacy paths such as
# "/Playlists/Bob/bb12.html" are kept as-is. Some legacy hrefs arrive wrapped
# in JavaScript/quote debris (e.g. "\";/Playlists/Bob/bb19990303.html\""), so
# quotes, semicolons and backslashes are stripped.
normalize_show_id <- function(href) {
  href |>
    stringr::str_remove_all("[\"';\\\\]") |>
    stringr::str_squish() |>
    stringr::str_remove("^/playlists/")
}

# TRUE for ids that point at a DJ landing page or year page ("WA", "WA2024")
# rather than an individual playlist. These appear when a DJ page mentions a
# fill-in for another DJ next to a date.
is_dj_page <- function(show_id) {
  stringr::str_detect(show_id, "^[A-Za-z0-9]{2}(\\d{4})?/?$")
}

# Full URL of an individual playlist page from a cached show_id. Handles
# modern ids ("shows/168921"), legacy site paths ("/Playlists/Bob/bb12.html")
# and absolute legacy URLs ("http://www.wfmu.org/Playlists/...").
show_page_url <- function(show_id) {
  dplyr::case_when(
    stringr::str_detect(show_id, "^https?://") ~ show_id,
    stringr::str_detect(show_id, "^/") ~ paste0(wfmu_root, show_id),
    .default = paste0(base_url, "/", show_id)
  )
}

# Build a playlist-site URL from a path fragment such as "AQ" or "shows/168921".
playlist_url <- function(path) {
  paste0(base_url, "/", stringr::str_remove(path, "^/?playlists/"))
}
