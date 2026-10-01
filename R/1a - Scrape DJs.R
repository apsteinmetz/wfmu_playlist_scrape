# 1a - Scrape DJs
#
# Build the DJ roster and the list of playlist URLs for WFMU.org.
#
# Outputs (formats consumed by 1b and the Shiny app; do not change columns):
#   data/wfmu_show_urls.rds     cache: DJ, AirDate, show_id      (all DJs)
#   data/dj_profiles.rds        cache: DJ, profileURL, other_shownames
#   data/dj_music_status.rds    cache: DJ, n_checked, median_songs, music_show, checked_on
#   data/excluded_shows.rds     non-music DJs: DJ, ShowName, Channel, onSched
#   data/playlistURLs.parquet   DJ, AirDate, show_id           (music DJs only)
#   data/dj_key.parquet         one row per DJ with show metadata
#
# Run modes (set MODE below):
#   "update"  Re-read current-season pages of on-schedule DJs not known to be
#             non-music. DJs never scraped before get full history and a
#             profile fetch; everyone else reuses the cached profile. (default)
#   "full"    Re-scrape every DJ's full history. Slow; use when the cache is
#             suspect or many prior-year shows are missing.
#   "cached"  No scraping of DJ pages; rebuild outputs from the cache files.
#
# Music vs. talk shows are detected automatically (see
# func_detect_music_show.R) and cached, so each run only checks DJs that are
# new or listed in RECHECK_MUSIC. Use MUSIC_OVERRIDES to force a decision.

library(tidyverse)
library(rvest)
library(xml2)
library(duckplyr)

duckplyr::methods_restore()

source(here::here("R", "func_wfmu_http.R"))
source(here::here("R", "func_get_show_names.R"))
source(here::here("R", "func_get_show_links.R"))
source(here::here("R", "func_detect_music_show.R"))

# ==================================================================
# Settings

MODE <- "update"

# In update mode, also re-read archived (off-schedule) DJs' pages. They rarely
# get new shows; turn on occasionally to catch fill-ins.
SCRAPE_ARCHIVED <- FALSE

# Force classification regardless of what the detector says.
MUSIC_OVERRIDES <- list(
  # RA (Raw Sewage): archived; recent pages score ~4 songs, but the existing
  # playlists file averages 4.7 real song rows/show over 35 shows.
  music = c("RA"),
  non_music = character(0)
)

# DJs whose music/talk status should be re-evaluated this run.
RECHECK_MUSIC <- character(0)
RECHECK_ALL_MUSIC <- FALSE

# Detection parameters: median artist count across the N most recent shows.
MUSIC_N_SHOWS <- 3
MUSIC_MIN_SONGS <- 5

# Words from ShowName used as a short label.
TOKEN_WORDS <- 2

paths <- list(
  show_urls = "data/wfmu_show_urls.rds",
  dj_profiles = "data/dj_profiles.rds",
  music_status = "data/dj_music_status.rds",
  excluded_shows = "data/excluded_shows.rds",
  playlist_urls = "data/playlistURLs.parquet",
  dj_key = "data/dj_key.parquet"
)

stopifnot(MODE %in% c("update", "full", "cached"))

# ==================================================================
# Helpers

read_cache <- function(path, empty) {
  if (file.exists(path)) readRDS(path) else empty
}

empty_profiles <- tibble(
  DJ = character(0),
  profileURL = character(0),
  other_shownames = character(0)
)

# One row per DJ. Older caches hold near-duplicates that differ only in the
# profile URL host (wfmu.org vs www.wfmu.org) or in other_shownames (e.g. a
# co-hosted show scraped from each host's profile). Keep the www URL and the
# union of other show names.
dedupe_profiles <- function(profiles) {
  profiles |>
    arrange(DJ, !str_detect(profileURL, "//www\\.")) |>
    summarise(
      .by = DJ,
      profileURL = first(profileURL),
      other_shownames = other_shownames |>
        str_split("\n") |>
        unlist() |>
        str_trim() |>
        setdiff(c("", "none")) |>
        paste(collapse = "\n")
    ) |>
    mutate(other_shownames = if_else(other_shownames == "", "none", other_shownames))
}

# ==================================================================
# 1. DJ roster from the playlists index

show_names <- get_show_names() |>
  arrange(DJ)

# ==================================================================
# 2. Load caches

show_urls <- read_cache(paths$show_urls, empty_show_links()) |>
  # repair ids cached by older versions of the parser (no-op once clean)
  mutate(show_id = normalize_show_id(show_id)) |>
  filter(show_id != "", !is_dj_page(show_id)) |>
  distinct(DJ, show_id, .keep_all = TRUE)
dj_profiles <- read_cache(paths$dj_profiles, empty_profiles) |>
  dedupe_profiles()

music_status <- read_cache(
  paths$music_status,
  detect_music_shows(show_urls, character(0))
)

# DJs averaging > MUSIC_MIN_SONGS rows per show in the existing playlists file
# are known music shows, so they skip the live check. This mostly matters on
# the first run, before the status cache exists.
music_status <- music_status |>
  rows_insert(
    music_status_from_playlists(min_songs = MUSIC_MIN_SONGS),
    by = "DJ",
    conflict = "ignore"
  )

# ==================================================================
# 3. Playlist URLs and profiles (cached + newly scraped)

# A talk verdict is only trusted once it rests on MUSIC_N_SHOWS aired shows.
# Provisional verdicts (new DJs with 1-2 shows) keep being scraped and are
# re-tested as more shows appear.
known_non_music <- music_status |>
  filter(!music_show, n_checked >= MUSIC_N_SHOWS) |>
  pull(DJ) |>
  union(MUSIC_OVERRIDES$non_music) |>
  setdiff(c(RECHECK_MUSIC, MUSIC_OVERRIDES$music))

scrape_plan <- show_names |>
  distinct(DJ, onSched) |>
  mutate(
    # "new" = never scraped before; dj_profiles has a row for every DJ we've
    # visited, even ones whose pages had no playlist links.
    is_new = !(DJ %in% dj_profiles$DJ),
    full_history = MODE == "full" | is_new,
    fetch_profile = MODE == "full" | is_new
  ) |>
  filter(
    MODE != "cached",
    MODE == "full" |
      is_new |
      ((onSched | SCRAPE_ARCHIVED) & !(DJ %in% known_non_music))
  )

if (nrow(scrape_plan) > 0) {
  message(
    "Scraping ", nrow(scrape_plan), " DJs (",
    sum(scrape_plan$full_history), " with full history, ",
    sum(scrape_plan$fetch_profile), " profile fetches)..."
  )

  scraped <- pmap(
    select(scrape_plan, DJ, full_history, fetch_profile),
    \(DJ, full_history, fetch_profile) {
      scrape_dj(DJ, full_history = full_history, fetch_profile = fetch_profile)
    }
  )

  new_urls <- map(scraped, "links") |> list_rbind()
  new_profiles <- map(scraped, "profile") |> compact() |> list_rbind()

  # Fresh dates replace cached ones for modern links (read from the episode
  # entry, so authoritative). Legacy links keep their cached date: several
  # weekly entries can share one monthly legacy page, and a date that flips
  # between runs would make 1b scrape the same page again.
  is_modern <- str_detect(new_urls$show_id, "^shows/")
  show_urls <- bind_rows(new_urls[is_modern, ], show_urls, new_urls[!is_modern, ]) |>
    distinct(DJ, show_id, .keep_all = TRUE) |>
    arrange(DJ, desc(AirDate))

  if (!is.null(new_profiles) && nrow(new_profiles) > 0) {
    dj_profiles <- dj_profiles |>
      rows_upsert(new_profiles, by = "DJ") |>
      arrange(DJ)
  }

  saveRDS(show_urls, paths$show_urls)
  saveRDS(dj_profiles, paths$dj_profiles)
}

# ==================================================================
# 4. Music vs. talk classification (only DJs not yet classified)

# Provisional talk verdicts with more aired shows available than were tested.
provisional <- music_status |>
  filter(!music_show, n_checked < MUSIC_N_SHOWS) |>
  inner_join(
    show_urls |> filter(AirDate <= Sys.Date()) |> count(DJ, name = "n_aired"),
    by = "DJ"
  ) |>
  filter(n_aired > n_checked) |>
  pull(DJ)

to_check <- show_names$DJ |>
  setdiff(if (RECHECK_ALL_MUSIC) character(0) else music_status$DJ) |>
  union(RECHECK_MUSIC) |>
  union(provisional) |>
  intersect(show_names$DJ)

if (length(to_check) > 0) {
  music_status <- music_status |>
    rows_upsert(
      detect_music_shows(
        show_urls, to_check,
        n_shows = MUSIC_N_SHOWS, min_songs = MUSIC_MIN_SONGS
      ),
      by = "DJ"
    ) |>
    arrange(DJ)
  saveRDS(music_status, paths$music_status)
}

show_names <- show_names |>
  left_join(select(music_status, DJ, music_show), by = "DJ") |>
  mutate(
    music_show = case_when(
      DJ %in% MUSIC_OVERRIDES$music ~ TRUE,
      DJ %in% MUSIC_OVERRIDES$non_music ~ FALSE,
      is.na(music_show) ~ FALSE,
      .default = music_show
    )
  )

excluded_shows <- show_names |>
  filter(!music_show) |>
  select(DJ, ShowName, Channel, onSched) |>
  arrange(DJ)
saveRDS(excluded_shows, paths$excluded_shows)

message(
  nrow(show_names), " DJs: ", sum(show_names$music_show), " music, ",
  nrow(excluded_shows), " excluded"
)

# ==================================================================
# 5. Outputs

music_djs <- show_names$DJ[show_names$music_show]

# Future-dated pages are empty placeholders; they stay in the cache and are
# released here once the show has aired.
playlist_urls <- show_urls |>
  filter(DJ %in% music_djs, AirDate <= Sys.Date())
compute_parquet(playlist_urls, paths$playlist_urls)

show_stats <- playlist_urls |>
  summarise(
    .by = DJ,
    showCount = n(),
    FirstShow = min(AirDate, na.rm = TRUE),
    LastShow = max(AirDate, na.rm = TRUE)
  )

# one-to-one joins error out if either side has a repeated DJ code
dj_key <- dj_profiles |>
  left_join(show_names, by = "DJ", relationship = "one-to-one") |>
  left_join(show_stats, by = "DJ", relationship = "one-to-one") |>
  mutate(
    ShowToken = str_squish(ShowName) |> str_to_title(),
    ShowToken = word(ShowToken, 1, pmin(TOKEN_WORDS, str_count(ShowToken, "\\S+"))),
    # other_shownames lists every show on the profile; drop the primary one
    other_shownames = map2_chr(
      other_shownames, ShowName,
      \(others, primary) {
        if (is.na(primary) || primary == "") others else str_remove(others, fixed(primary))
      }
    ) |>
      str_remove("'s show") |>
      str_replace_all("\\n{2,}", "\n") |>
      str_remove("^\\n") |>
      str_trim(),
    other_shownames = if_else(other_shownames == "", "none", other_shownames)
  ) |>
  distinct() |>
  select(
    DJ, ShowName, onSched, Channel, music_show, other_shownames,
    showCount, FirstShow, LastShow, profileURL, ShowToken
  )

dup_djs <- unique(dj_key$DJ[duplicated(dj_key$DJ)])
if (length(dup_djs) > 0) {
  stop("dj_key has repeated DJ codes: ", paste(dup_djs, collapse = ", "))
}

compute_parquet(dj_key, paths$dj_key)
