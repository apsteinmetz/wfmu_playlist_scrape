# 2 - Clean playlists
#
# Rebuild the canonical playlists table from playlists_raw on every run, so
# artist tokens and signature songs are always computed from full history.
#
# Inputs:
#   data/playlists_raw.parquet      DJ, AirDate, Artist, Title   (from 1b)
#   data/dj_key.parquet             ShowToken, ShowName per DJ   (from 1a)
#   config/non_song_patterns.csv    patterns for rows that aren't songs
#
# Outputs:
#   data/playlists.parquet          DJ, AirDate, Artist, Title, ArtistToken, Signature
#                                   Rows within a show are in play order (the
#                                   app orders a show by parquet row number).
#                                   Signature = TRUE marks a DJ's signature song
#                                   in a show's opening or closing slot; rows are
#                                   kept, so filter on it where needed.
#   data/all_artisttokens.rdata     sorted unique ArtistToken values
#   data/dj_key.parquet             showCount, FirstShow, LastShow updated
#   data/non_song_candidates.csv    rows that look like talk, for review; add
#                                   confirmed patterns to the patterns file

library(tidyverse)

source(here::here("R", "func_clean_playlists.R"))

# ==================================================================
# Settings

MIN_AIRDATE <- as.Date("1982-01-01")
CL_MIN_AIRDATE <- as.Date("1997-01-01")

# Replace each artist token with the most common spelling of that artist.
CONDENSE_ARTISTS <- TRUE

# A song opening or closing this many consecutive shows is a signature song.
SIGNATURE_MIN_RUN <- 6

CANDIDATES_TOP_N <- 500

paths <- list(
  playlists_raw = "data/playlists_raw.parquet",
  dj_key = "data/dj_key.parquet",
  non_song_patterns = "config/non_song_patterns.csv",
  playlists = "data/playlists.parquet",
  all_artisttokens = "data/all_artisttokens.rdata",
  candidates = "data/non_song_candidates.csv"
)

# ==================================================================
# 1. Inputs

raw <- arrow::read_parquet(paths$playlists_raw)
dj_key <- arrow::read_parquet(paths$dj_key)
non_song_patterns <- read_non_song_patterns(paths$non_song_patterns)

# ==================================================================
# 2. Clean

start_time <- Sys.time()
playlists <- clean_playlists(
  raw, dj_key, non_song_patterns,
  min_airdate = MIN_AIRDATE,
  cl_min_airdate = CL_MIN_AIRDATE,
  condense_artists = CONDENSE_ARTISTS,
  signature_min_run = SIGNATURE_MIN_RUN
)
message(sprintf(
  "Cleaned %s raw rows to %s in %.1f min",
  format(nrow(raw), big.mark = ","), format(nrow(playlists), big.mark = ","),
  as.numeric(difftime(Sys.time(), start_time, units = "mins"))
))

# ==================================================================
# 3. Outputs

arrow::write_parquet(playlists, paths$playlists)

all_artisttokens <- sort(unique(playlists$ArtistToken))
save(all_artisttokens, file = paths$all_artisttokens)

show_stats <- playlists |>
  summarise(
    .by = DJ,
    showCount = n_distinct(AirDate),
    FirstShow = min(AirDate),
    LastShow = max(AirDate)
  )
dj_key <- dj_key |>
  rows_update(show_stats, by = "DJ", unmatched = "ignore") |>
  arrange(DJ)
arrow::write_parquet(dj_key, paths$dj_key)

# ==================================================================
# 4. Non-song candidate report

candidates <- non_song_candidates(playlists, dj_key, top_n = CANDIDATES_TOP_N)
write_csv(candidates, paths$candidates)
message(nrow(candidates), " candidate non-song strings written to ", paths$candidates)

# ==================================================================
# 5. Summary

tibble(
  rows = nrow(playlists),
  shows = nrow(distinct(playlists, DJ, AirDate)),
  djs = n_distinct(playlists$DJ),
  earliest = min(playlists$AirDate),
  latest = max(playlists$AirDate),
  signature_plays = sum(playlists$Signature),
  artist_tokens = length(all_artisttokens),
  titles = n_distinct(playlists$Title)
) |>
  print()
