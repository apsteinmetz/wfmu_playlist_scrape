# WFMU Playlist Scrape

Scrapes and processes DJ playlist data from [WFMU.org](https://wfmu.org) for use in a companion Shiny app (`wfmu_explorer`). The pipeline is a sequence of numbered R scripts that build up a set of parquet data files.

## Pipeline

Run the scripts in order. Each step reads from `data/` and writes back to `data/`.

| Script | Purpose |
|--------|---------|
| `R/1a - Scrape DJs.R` | Scrapes the DJ roster, classifies shows as music or talk, and builds the DJ key and playlist URL index. |
| `R/1b - Scrape playlists.R` | Downloads individual playlist pages and appends new plays to `playlists_raw.parquet`. Writes checkpoints to `playlists_temp.parquet` so interrupted runs can be recovered. |
| `R/2 - clean_playlists.r` | Full rebuild of `playlists.parquet` from raw: drops non-songs, normalises artist tokens, flags signature songs, and updates show counts in `dj_key.parquet`. |
| `R/3 - precalc_similiarity.r` | Computes pairwise DJ cosine similarity, distinctive-artist lists (weighted log-odds), and a pre-rendered similarity histogram. |
| `R/4 - save files parquet.R` | Copies the six files the Shiny app reads into `../wfmu_explorer/data/`. |

## Key Settings

Each script has a settings block near the top. Commonly adjusted options:

**1a**
- `MODE` — `"update"` (default, ~2–3 min), `"full"` (all DJs), or `"cached"` (no web requests).
- `SCRAPE_ARCHIVED` — set `TRUE` occasionally to catch fill-in shows from archived DJs.

**1b**
- `MAX_SHOWS` — cap on shows scraped per run; useful for testing (e.g. `MAX_SHOWS <- 20`).
- `CHECKPOINT_EVERY` — how often `playlists_temp.parquet` is written (default 100 shows).

**2**
- `SIGNATURE_MIN_RUN` — consecutive shows a song must open/close to be flagged as a signature (default 6).

**3**
- `HALF_LIFE_DAYS` — recency decay for similarity weighting (default 365).

## Data Files

All data files live in `data/` and are tracked with Git LFS.

| File | Description |
|------|-------------|
| `playlists.parquet` | Cleaned playlist rows: `DJ`, `AirDate`, `Artist`, `Title`, `ArtistToken`, `Signature`. |
| `playlists_raw.parquet` | Raw scraped rows, one per play as scraped. |
| `playlistURLs.parquet` | Music-DJ playlist URL index used by 1b. |
| `dj_key.parquet` | One row per DJ with show metadata. |
| `djsimilarity.parquet` | Pairwise DJ cosine similarity scores. |
| `distinctive_artists.parquet` | Top 100 distinctive artists per DJ (weighted log-odds). |
| `similarity_histogram_gg.rdata` | Pre-rendered ggplot histogram for the app. |
| `djdtm.rdata` | Legacy document-term matrix used by the app's chord plot. |

Cache files (`wfmu_show_urls.rds`, `dj_profiles.rds`, `dj_music_status.rds`, `excluded_shows.rds`) are read and written by scripts 1a/1b to avoid redundant web requests.

## Helper Modules

| File | Role |
|------|------|
| `R/func_wfmu_http.R` | Shared HTTP helpers and constants; source before running 1a or 1b. |
| `R/func_get_show_names.R` | DJ roster scraping. |
| `R/func_get_show_links.R` | Per-DJ playlist link scraping and date parsing. |
| `R/func_detect_music_show.R` | Music-vs-talk classification logic. |
| `R/func_parse_playlist.R` | Multi-parser playlist table extraction. |
| `R/func_clean_playlists.R` | Cleaning pipeline and signature-song detection. |
| `R/func_similarity.R` | Cosine similarity, distinctive artists, and histogram. |

## Non-Song Patterns

`config/non_song_patterns.csv` contains regex patterns used by step 2 to drop rows that are page text or show notes rather than song plays. Each run of script 2 writes `data/non_song_candidates.csv` — a ranked list of candidate non-song strings for review. Confirmed patterns are added to the config file manually.

## Project Documentation

See [`agents/scrape_wfmu.md`](agents/scrape_wfmu.md) for detailed notes on each script's behaviour, settings, data-quality rules, and open issues.
