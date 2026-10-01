# 3 - Precalculate DJ similarity and distinctive artists
#
# Inputs:
#   data/playlists.parquet               from step 2
#
# Outputs (formats read by the app; do not change columns):
#   data/djsimilarity.parquet            DJ1, DJ2, Similarity (cosine, 0-1)
#   data/distinctive_artists.parquet     DJ, ArtistToken: top artists per DJ,
#                                        most distinctive first (the app shows
#                                        every column except DJ)
#   data/similarity_histogram_gg.rdata   ggplot `gg_sim`; the app uses its
#                                        first layer's bins and its labels
#   data/djdtm.rdata                     `djdtm`, a tm DocumentTermMatrix of
#                                        DJ x artist-word counts (chord plot)
#
# Plays flagged as Signature (signature songs, show furniture) are left out.

library(tidyverse)

source(here::here("R", "func_similarity.R"))

# ==================================================================
# Settings

# Recency: a play's weight halves every HALF_LIFE_DAYS before the latest show.
HALF_LIFE_DAYS <- 365

# Relative weight of artist terms and song (artist + title) terms.
ARTIST_WEIGHT <- 1.5
SONG_WEIGHT <- 1

# Titles shorter than this (after removing punctuation) are not song terms.
MIN_TITLE_LENGTH <- 3

# Sublinear term frequency: log1p(count) instead of count.
SUBLINEAR_TF <- TRUE

# Distinctive artists kept per DJ.
DISTINCTIVE_N <- 100

# Chord-plot matrix keeps artist words used by more than 1 - DTM_SPARSE of DJs.
DTM_SPARSE <- 0.95

paths <- list(
  playlists = "data/playlists.parquet",
  similarity = "data/djsimilarity.parquet",
  distinctive = "data/distinctive_artists.parquet",
  histogram = "data/similarity_histogram_gg.rdata",
  dtm = "data/djdtm.rdata"
)

# ==================================================================
# 1. Inputs

playlists <- arrow::read_parquet(
  paths$playlists,
  col_select = c(DJ, AirDate, ArtistToken, Title, Signature)
) |>
  filter(!Signature)

# ==================================================================
# 2. Similarity

start_time <- Sys.time()
terms <- similarity_terms(
  playlists,
  ref_date = max(playlists$AirDate),
  half_life_days = HALF_LIFE_DAYS,
  artist_weight = ARTIST_WEIGHT,
  song_weight = SONG_WEIGHT,
  min_title_length = MIN_TITLE_LENGTH
)
dj_similarity <- dj_cosine_similarity(terms, sublinear = SUBLINEAR_TF)
arrow::write_parquet(dj_similarity, paths$similarity)

# ==================================================================
# 3. Distinctive artists

distinctive <- distinctive_artists(playlists, n = DISTINCTIVE_N)
arrow::write_parquet(distinctive, paths$distinctive)

# ==================================================================
# 4. Histogram

gg_sim <- similarity_histogram(dj_similarity)
save(gg_sim, file = paths$histogram)

# ==================================================================
# 5. DJ x artist-word matrix for the chord plot

djdtm <- dj_artist_dtm(playlists, sparse = DTM_SPARSE)
save(djdtm, file = paths$dtm)

message(sprintf(
  "%s DJs, %s terms, %s DJ pairs, %s distinctive artists in %.1f min",
  n_distinct(terms$DJ), format(n_distinct(terms$term), big.mark = ","),
  format(nrow(dj_similarity), big.mark = ","), format(nrow(distinctive), big.mark = ","),
  as.numeric(difftime(Sys.time(), start_time, units = "mins"))
))
