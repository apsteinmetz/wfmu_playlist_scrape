# 2 - Clean playlists
#
# Rebuild the canonical playlists table from playlists_raw on every run, so
# artist tokens and signature songs are always computed from full history.
#
# Inputs:
#   data/playlists_raw.parquet      DJ, AirDate, Seq, Artist, Title   (from 1b)
#                                   Seq = play order; NA for rows scraped
#                                   before it existed (file order is used)
#   data/dj_key.parquet             ShowToken, ShowName per DJ   (from 1a)
#   config/non_song_patterns.csv    patterns for rows that aren't songs
#   config/signature_share_exclusions.csv
#                                   songs the share test must not flag
#   config/signature_includes.csv   songs always flagged as signature songs
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

source(here::here("R", "func_progress.R"))
source(here::here("R", "func_clean_playlists.R"))

# ==================================================================
# Settings

MIN_AIRDATE <- as.Date("1982-01-01")
CL_MIN_AIRDATE <- as.Date("1997-01-01")

# Replace each artist token with the most common spelling of that artist.
CONDENSE_ARTISTS <- TRUE

# A song opening or closing this many consecutive shows is a signature song.
SIGNATURE_MIN_RUN <- 6

# A song in more than this share of a DJ's shows is also a signature song
# (works without play order, which is unknown for most pre-2025 shows). Only
# for DJs with SIGNATURE_SHARE_MIN_SHOWS+ shows and songs played in
# SIGNATURE_SHARE_MIN_PLAYS+ shows.
SIGNATURE_MIN_SHARE <- 0.5
SIGNATURE_SHARE_MIN_SHOWS <- 50
SIGNATURE_SHARE_MIN_PLAYS <- 10

CANDIDATES_TOP_N <- 500

paths <- list(
  playlists_raw = "data/playlists_raw.parquet",
  dj_key = "data/dj_key.parquet",
  non_song_patterns = "config/non_song_patterns.csv",
  share_exclusions = "config/signature_share_exclusions.csv",
  signature_includes = "config/signature_includes.csv",
  playlists = "data/playlists.parquet",
  all_artisttokens = "data/all_artisttokens.rdata",
  candidates = "data/non_song_candidates.csv"
)

# ==================================================================
# 1. Inputs

progress_start()
progress("Step 2: reading inputs")
raw <- arrow::read_parquet(paths$playlists_raw)
dj_key <- arrow::read_parquet(paths$dj_key)
non_song_patterns <- read_non_song_patterns(paths$non_song_patterns)
share_exclusions <- read_share_exclusions(paths$share_exclusions)
signature_includes <- read_signature_includes(paths$signature_includes)

# ==================================================================
# 2. Clean

playlists <- clean_playlists(
  raw, dj_key, non_song_patterns,
  min_airdate = MIN_AIRDATE,
  cl_min_airdate = CL_MIN_AIRDATE,
  condense_artists = CONDENSE_ARTISTS,
  signature_min_run = SIGNATURE_MIN_RUN,
  signature_min_share = SIGNATURE_MIN_SHARE,
  signature_share_min_shows = SIGNATURE_SHARE_MIN_SHOWS,
  signature_share_min_plays = SIGNATURE_SHARE_MIN_PLAYS,
  signature_share_exclusions = share_exclusions,
  signature_includes = signature_includes
)
progress(
  "Cleaned ", fmt_n(nrow(raw)), " raw rows to ", fmt_n(nrow(playlists)),
  " (", fmt_n(sum(playlists$Signature)), " signature plays)"
)

# ==================================================================
# 3. Outputs

progress("Writing ", paths$playlists, ", artist tokens and ", paths$dj_key)
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

progress("Building non-song candidate report")
candidates <- non_song_candidates(playlists, dj_key, top_n = CANDIDATES_TOP_N)
write_csv(candidates, paths$candidates)
progress(nrow(candidates), " candidate non-song strings written to ", paths$candidates)

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
progress("Step 2 done")
