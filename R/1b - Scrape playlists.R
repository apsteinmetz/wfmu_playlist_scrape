# 1b - Scrape playlists
#
# Scrape the songs for every music-show playlist listed by step 1a that is not
# yet in playlists_raw, and append them.
#
# Inputs:
#   data/dj_key.parquet         music_show flag per DJ          (from 1a)
#   data/playlistURLs.parquet   DJ, AirDate, show_id            (from 1a)
#   data/playlists_raw.parquet  all scraped songs so far
#
# Outputs (formats consumed by step 2; do not change columns):
#   data/playlists_temp.parquet DJ, AirDate, Artist, Title — rows new this run
#   data/playlists_raw.parquet  DJ, AirDate, Artist, Title — all rows
#
# "Already scraped" means the DJ + AirDate pair appears in playlists_raw. A page
# that parses to no songs is stored as one blank row (Artist = Title = "") and
# is never retried. A page that can't be fetched stores nothing and is retried
# on the next run.
#
# playlists_temp is saved every CHECKPOINT_EVERY shows. If a run is
# interrupted, the next run keeps those rows instead of re-scraping them.

library(tidyverse)
library(rvest)
library(xml2)
library(duckplyr)

duckplyr::methods_restore()

source(here::here("R", "func_wfmu_http.R"))
source(here::here("R", "func_parse_playlist.R"))

# ==================================================================
# Settings

# Cap on shows scraped this run (Inf = all). Use a small number for testing.
MAX_SHOWS <- Inf

CHECKPOINT_EVERY <- 100

paths <- list(
  dj_key = "data/dj_key.parquet",
  playlist_urls = "data/playlistURLs.parquet",
  playlists_raw = "data/playlists_raw.parquet",
  playlists_temp = "data/playlists_temp.parquet"
)

empty_songs <- tibble(
  DJ = character(0),
  AirDate = as.Date(character(0)),
  Artist = character(0),
  Title = character(0)
)

# ==================================================================
# 1. Inputs

music_djs <- arrow::read_parquet(paths$dj_key, col_select = c(DJ, music_show)) |>
  filter(music_show %in% TRUE) |>
  pull(DJ)

playlist_urls <- arrow::read_parquet(paths$playlist_urls) |>
  filter(DJ %in% music_djs)

playlists_raw <- arrow::read_parquet(paths$playlists_raw)
scraped_shows <- distinct(playlists_raw, DJ, AirDate)

# ==================================================================
# 2. Recover rows from an interrupted run
#
# After a completed run every show in playlists_temp is also in
# playlists_raw. Shows that aren't mean the last run stopped before merging.

leftover <- if (file.exists(paths$playlists_temp)) {
  arrow::read_parquet(paths$playlists_temp) |>
    anti_join(scraped_shows, by = c("DJ", "AirDate"))
} else {
  empty_songs
}
if (nrow(leftover) > 0) {
  message("Recovered ", n_distinct(leftover$DJ, leftover$AirDate), " shows from an interrupted run")
}

# ==================================================================
# 3. Shows to scrape

pending <- playlist_urls |>
  anti_join(scraped_shows, by = c("DJ", "AirDate")) |>
  anti_join(distinct(leftover, DJ, AirDate), by = c("DJ", "AirDate")) |>
  filter(!is_dj_page(show_id)) |>
  slice_head(n = MAX_SHOWS)

message("Scraping ", nrow(pending), " playlists...")

# ==================================================================
# 4. Scrape, checkpointing to playlists_temp

write_temp <- function(new_results) {
  bind_rows(leftover, select(new_results, -method)) |>
    compute_parquet(paths$playlists_temp)
}

results <- vector("list", nrow(pending))
start_time <- Sys.time()

for (i in seq_len(nrow(pending))) {
  results[[i]] <- scrape_playlist(pending$DJ[i], pending$AirDate[i], pending$show_id[i])

  if (i %% CHECKPOINT_EVERY == 0) {
    message(sprintf(
      "  %d / %d shows (%.1f min)", i, nrow(pending),
      as.numeric(difftime(Sys.time(), start_time, units = "mins"))
    ))
    write_temp(list_rbind(results[seq_len(i)]))
  }
}

# start from a typed empty frame so zero pending shows still gives the columns
new_rows <- bind_rows(mutate(empty_songs, method = character(0)), list_rbind(results))

# ==================================================================
# 5. Report

if (nrow(pending) > 0) {
  outcome <- pending |>
    mutate(
      method = map_chr(results, \(r) if (nrow(r) == 0) "fetch failed" else r$method[1]),
      n_songs = map_int(results, \(r) sum(r$Artist != ""))
    )
  message("Playlists by parser:")
  outcome |>
    summarise(.by = method, shows = n(), songs = sum(n_songs)) |>
    arrange(desc(shows)) |>
    print()
  n_failed <- sum(outcome$method == "fetch failed")
  if (n_failed > 0) {
    message(n_failed, " pages could not be fetched; they will be retried next run")
  }
}

# ==================================================================
# 6. Outputs

playlists_temp <- bind_rows(leftover, select(new_rows, -method))
compute_parquet(playlists_temp, paths$playlists_temp)

playlists_raw <- bind_rows(playlists_raw, playlists_temp) |>
  distinct()
compute_parquet(playlists_raw, paths$playlists_raw)
