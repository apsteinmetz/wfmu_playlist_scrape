---
title: "Scrape Playlists at WFMU.org"
---

# Overall Goal of the exising scripts

Update the data files containing the WFMU.org playlists with  playlists not already present in the data files. The data files are stored in the `data/` directory.  The data files are created by a sequential series of scripts, executed in order,  that scrape the WFMU.org website for playlists, DJ, Channel and Show information. Then they clean the newly scraped data and merge it with the existing data files.  The data files are then copied over to another directory for use in a Shiny app.

# Goal of this project

1. Generally improve the code to make it more efficient and easier to maintain.
2. Improve the quality of the results that are scraped and cleaned.
3. The format of the data files should be maintained so that the shiny app can continue to use them without any changes.
4. Work on each of the sequential scripts individually and in order.

# The existing scripts purpose and improvement opportunities

## 1a - Scrape DJs.R

### Purpose

This script scrapes the WFMU.org website for DJ information, including playlist links, show names, and show features.  Most of the information is already present as the DJ roster does not change much over time.  To make things efficient this script tries to update only new information.  A crucial feature is that it distinguishes between DJs that have music shows and those that don't.  We are only interested in DJs that have music shows.

### Opportunities for improvement (done, September 2026)

1. ~~The DJs with non-music shows are hard-coded.~~ Replaced by automatic detection (see "Music-show detection" below).
2. ~~The logic for deciding on what to update is sloppy.~~ Rewritten around a single `MODE` setting, cached state files, and side-effect-free helper functions.

### Files

| File | Role |
|---|---|
| `R/1a - Scrape DJs.R` | Main script. Sections: settings, roster, load caches, scrape links, classify music/talk, write outputs. |
| `R/func_wfmu_http.R` | Shared constants (`base_url`, `ua`, `pause`, `date_pattern`) and helpers: `safe_get_html()`, `playlist_url()`, `show_page_url()`, `normalize_show_id()`, `is_dj_page()`. Source first. |
| `R/func_get_show_names.R` | `get_show_names()`: DJ roster from the playlists index plus alternate-stream channels. One row per DJ. |
| `R/func_get_show_links.R` | `scrape_dj(dj, full_history, fetch_profile)`: returns `list(links, profile)`. No global side effects. |
| `R/func_detect_music_show.R` | `music_status_from_playlists()` (offline seed) and `detect_music_shows()` (live check). |

### Run modes (`MODE`)

| Mode | What it scrapes |
|---|---|
| `"update"` (default) | Current-season pages of on-schedule DJs not confidently classified as non-music. DJs never scraped before (not in `dj_profiles.rds`) also get full history and a profile fetch. Typical run: ~160 page requests, 2-3 minutes. |
| `"full"` | Every DJ's full history and profile. Slow; use when the cache is suspect. |
| `"cached"` | No DJ-page scraping; rebuild outputs from cache files. (Still reads the roster index.) |

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `SCRAPE_ARCHIVED` | `FALSE` | In update mode, also read archived (off-schedule) DJs' pages. Turn on occasionally to catch fill-ins. |
| `MUSIC_OVERRIDES` | `list(music = "RA", non_music = character(0))` | Force classification. Overrides beat the detector. RA (Raw Sewage) is borderline and forced to music. |
| `RECHECK_MUSIC` | `character(0)` | DJ codes to re-test this run. |
| `RECHECK_ALL_MUSIC` | `FALSE` | Re-test every DJ (~3 playlist fetches each). |
| `MUSIC_N_SHOWS` | `3` | Number of recent aired shows sampled per DJ. |
| `MUSIC_MIN_SONGS` | `5` | Song threshold for a music show. |
| `TOKEN_WORDS` | `2` | Words of `ShowName` used for `ShowToken`. |

### Music-show detection

The index page has no music/talk flag, and every playlist page uses the same table layout, so the signal is the number of non-empty `td.col_artist` cells per playlist. Talk shows list 0-3 rows; music shows list dozens.

1. **Offline seed.** DJs averaging more than `MUSIC_MIN_SONGS` rows per show (one show = `DJ` + `AirDate`) in `data/playlists.parquet` are marked music with no web requests. Only positives are seeded.
2. **Live check.** Unclassified DJs: median artist count across their `MUSIC_N_SHOWS` most recent *aired* playlists; music if the median is at least `MUSIC_MIN_SONGS`. DJs with no playlist links are non-music.
3. **Provisional verdicts.** A non-music verdict based on fewer than `MUSIC_N_SHOWS` shows is provisional: the DJ keeps being scraped and is re-tested when more aired shows exist. Only confident non-music DJs are skipped by the scrape.
4. **Caching.** Verdicts are stored in `data/dj_music_status.rds`; established DJs are never re-tested unless listed in `RECHECK_MUSIC`.

Note: the seed uses "more than" and the live check "at least"; this only matters for a DJ exactly at the threshold.

### Outputs

Formats of `playlistURLs.parquet` and `dj_key.parquet` must not change (used by 1b and the Shiny app).

| File | Contents |
|---|---|
| `data/wfmu_show_urls.rds` | Cache of playlist links for **all** DJs: `DJ`, `AirDate`, `show_id`. Includes future-dated links. |
| `data/dj_profiles.rds` | Cache: `DJ`, `profileURL`, `other_shownames`. One row per DJ. |
| `data/dj_music_status.rds` | Cache: `DJ`, `n_checked`, `median_songs`, `music_show`, `checked_on`. For seeded DJs, `n_checked` is the number of shows in the playlists file and `median_songs` is the mean rows per show. |
| `data/excluded_shows.rds` | Non-music DJs: `DJ`, `ShowName`, `Channel`, `onSched`. Used by `get_pledges.R`. |
| `data/playlistURLs.parquet` | Music DJs only, aired shows only: `DJ`, `AirDate`, `show_id`. |
| `data/dj_key.parquet` | One row per DJ (enforced): `DJ`, `ShowName`, `onSched`, `Channel`, `music_show`, `other_shownames`, `showCount`, `FirstShow`, `LastShow`, `profileURL`, `ShowToken`. |

### Data-quality rules

- `show_id` is normalised to `shows/NNNNNN`, or kept as a legacy path such as `/Playlists/Bob/bb12.html`. Quote/semicolon debris is stripped, and links to DJ landing or year pages (`WA`, `WA2024`) are dropped. The same cleaning is applied to the cache on load.
- Future-dated playlist pages are empty placeholders: kept in the cache, excluded from music sampling and from `playlistURLs.parquet` until they air.
- `dj_profiles` is de-duplicated on load (prefers the `www.` URL and merges other show names). `dj_key` joins are one-to-one, and the script stops if any DJ code repeats.

### Air-date rule

Implemented in `parse_show_links()` / `episode_dates()` in `R/func_get_show_links.R`.

- **Modern links** (`shows/NNNNNN`): each entry on a DJ page starts with `<span class="KDBepisode" id="KDBepisode-NNNNNN">`, immediately followed by its date (e.g. "March 22, 2020 (This show was originally aired on 6/27/2010):"). The date is read from there, keyed by the show number. This works regardless of page layout and ignores dates inside episode titles.
- **Links without an episode span** (mostly legacy): a date in the link text; otherwise the enclosing element's date if it holds exactly one, else the nearest date before the link (flat pages such as TW put every entry in one `<div>`).
- **Cache merge**: fresh dates replace cached ones for modern links; legacy links keep their cached date, because several weekly entries can share one monthly legacy page (e.g. DK's `dk.0109.html`) and a date that flips between runs would make 1b scrape the page again.
- The old rule (first date in the parent element) stamped every TW link with 2020-05-03 and shifted some BB, HI, R0 and D1 shows by a week. Fixed September 2026: 14 of 14 changed dates checked against the playlist page titles.

### Fill-in rule

Entries whose date text says "filled in" (e.g. "May 3, 2020 (Suzy Hotrod filled in.)", "Mary Wing filled in") mean another DJ hosted the slot. They are ignored because the show belongs to the other DJ's playlists. "Fill-in for Irene" entries are the DJ's own show in someone else's slot and are kept. The pattern is `fill_in_pattern` in `R/func_get_show_links.R`.

### Open issues

- E1 and TB are in `dj_key` (from the profile cache) but no longer on the roster; `music_show` is `NA`, so 1b skips them.
- S0 and W1 are archived DJs with provisional non-music verdicts; they are only re-scraped when `SCRAPE_ARCHIVED = TRUE`.
- Archived DJs' pages are only read in `"full"` mode or with `SCRAPE_ARCHIVED = TRUE`, so their cached dates still come from the old rule. TW was repaired by hand.

## 1b - Scrape Playlists.

### Purpose

This script uses the DJ playlist URLs to scrape the playlists for each DJ to create the master playlists file.  It saves time by comparing the dates of existing DJs and dates and only updates with new shows.

The script recognizes that there are varying HTML table styles for the playlists.  Most of the tables will be found by the code in the section commented "First Try."   Table header labels vary also. Older playlists vary more.  The script tries different known styles and gives up if no proper table is found.  Some shows have child pages for earlier year playlists from the same DJ. The script tries to detect that and reach into the prior years as well, if they are not already in the playlists file.

As a safety feature, newly scraped playlists are saved to an intermediate file every 100 playlists.

### Opportunities for improvement

Can the playlist table recognition be made more flexible and robust?  The key is to extract the artist and title from all playlists, at least.

*Status (September 2026): partly done.* Parsers are now small named functions tried in order, and each run reports how many shows each parser handled, so gaps are visible. No new layouts have been added yet.

*Decision (September 2026): no extra song metadata.* Album, year, label and other fields are not scraped. Playlists keep the original design of `Artist` and `Title` only.

Other code efficiencies.  Reuse code shared with previous scripts.

*Status: done.* See below.

### Files

| File | Role |
|---|---|
| `R/1b - Scrape playlists.R` | Main script. Sections: settings, inputs, recover interrupted run, shows to scrape, scrape with checkpoints, report, outputs. |
| `R/func_parse_playlist.R` | `scrape_playlist(dj, air_date, show_id)`, `parse_playlist(doc)`, `fetch_playlist_doc(url)` (follows the first `<frame>` of framed legacy pages), and the individual parsers. |
| `R/func_wfmu_http.R` | Shared with 1a: `safe_get_html()` (with `pause`), `show_page_url()` (modern ids, legacy paths and absolute legacy URLs), `is_dj_page()`. |

### Behaviour

- **Already scraped** = the `DJ` + `AirDate` pair is in `playlists_raw` (kept deliberately; there is no `show_id` in the raw file). All pending links for a new DJ-day are scraped in the same run.
- **Empty pages** are stored as one blank row (`Artist = Title = ""`) and never retried. **Pages that can't be fetched** store nothing and are retried next run.
- **Checkpoints**: `playlists_temp.parquet` is written every `CHECKPOINT_EVERY` shows. On start, rows in `playlists_temp` whose DJ-day isn't in `playlists_raw` are treated as an interrupted run: kept, merged, and not re-scraped.
- **Politeness**: every request waits `pause` (0.5 s), so about 1 second per show.

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `MAX_SHOWS` | `Inf` | Cap on shows scraped this run; use a small number for testing. |
| `CHECKPOINT_EVERY` | `100` | Shows between checkpoint writes. |

### Parser order

`parse_playlist()` returns the first parser that finds at least one song (at least 3 for `first_two_columns`):

1. `col_classes`: modern `td.col_artist` / `td.col_song_title` cells (almost all current shows).
2. `header_table`: any table with recognisable Artist/Title headers (`artist_header_names`, `title_header_names`).
3. `first_two_columns`: first two columns of one of the first two tables.
4. `td_song`: `td.song` cells holding "Title - Artist" (split order kept from the original code).
5. `single_column_table`: second table, second column holding "Artist\n-\nTitle" entries (e.g. BK).
6. `text_lines`: plain-text lines split on colon, quote or bar (e.g. DK, BT).

Old vs new parsers were compared on 36 real pages: 35 identical. The one difference was a fix: the old code stored "View Doug Schulkind's profile" as a song.

### Outputs

Formats unchanged (read by step 2):

| File | Contents |
|---|---|
| `data/playlists_temp.parquet` | `DJ`, `AirDate`, `Seq`, `Artist`, `Title`: rows new this run (plus any recovered rows). Used by 1b for recovery; step 2 no longer reads it. |
| `data/playlists_raw.parquet` | `DJ`, `AirDate`, `Seq`, `Artist`, `Title`: all scraped rows. `Seq` = position on the page; `NA` for rows scraped before it was added. |

### Data repair, September 2026

After the air-date fix, `playlists_raw` rows for the affected DJ-days were removed so 1b re-scrapes them with correct dates: TW's 2020-05-03 fill-in day, and both the old and corrected dates of the 151 re-dated BB, HI, R0 and D1 shows (6,596 rows, 152 DJ-days). The next 1b run re-scrapes about 206 links. The pre-repair file is `data/playlists_raw_pre_repair.parquet`.

1b then re-scraped them (1,679 shows in that run), and step 2 rebuilt `data/playlists.parquet` from `playlists_raw`, so the misdated rows are gone from the cleaned file too.

## 2 - clean_playlists.R

### Purpose

This script cleans up playlists_raw and adds the new rows to the canonical playlists file.  
 
 To account for artist names that vary even for the same artist, we create an artist token that reflects the most prevalent name of the artist while removing "the" from the beginning, if present.

 A major activity of this script is to try identify "signature songs" of a DJ and optionally strip those out of the playlists. Signature songs are songs which begin and end every show.

Another major activity is to identify playlist rows which are not actually songs.  I manually identify certain strings that indicate show information other than a song being played.  The list is not exhaustive.

Punctuation marks in artist names are converted to alphanumeric.

dj_key is updated with new show counts and first/last show dates.

summary statistics are reported at the end of the run

### Opportunties for improvement

A better technique for identifying signature songs is warranted.  Over time a DJ might change or drop a signature song.  Identify a signature song as one that begins or ends a show more than 5 consecutive shows from that DJ.  Flag the song as such with a new boolean column in the playlists file so that the choice to include or omit is not done in this script, but in a further use of the playlists file. Note that the same song can be both a signature song and not, depending on when its played.

*Status (September 2026): done.* `playlists.parquet` has a `Signature` column; rows are no longer stripped. A DJ-song qualifies if it opens or closes at least `SIGNATURE_MIN_RUN` (6) consecutive shows by that DJ. Only its opening (or closing) plays *inside* a qualifying run are flagged. The same song opening a show outside the run, or played mid-show, is not, so a DJ can adopt and drop signature songs over time. When finding runs, titles are compared without trailing version words (mono, stereo, mix, version, remaster(ed), single, edit, radio, album, or a year; see `signature_title_key()`), so "In The Courtyard Of The Stars Mono" and "... Stereo Mix" count as one song. The `Title` column itself is unchanged. Example: NO opened 1,976 shows with "In The Courtyard Of The Stars"; 1,939 are flagged and 37 fall in runs shorter than 6 shows.

**Show furniture** is also flagged as `Signature`, wherever in a show it is played: titles naming an intro, outro, jingle, promo, PSA, bumper, stinger, theme song, opening/closing theme or show open (`show_furniture_pattern`). Bare "theme" and "open" are not used ("Theme From Shaft", "Wide Open"), nor are "Jingle Bells"/"Jingle Jangle" or promo pressings ("promo single", "promo mix"). A title that is only "Intro" (or "Intro 2") is usually an album track and is not flagged as furniture (`bare_intro_pattern`); "Testify Intro" is. About 6,700 plays.

Current build: 13,849 flagged plays in total, 3,001 DJ-songs, 345 DJs. **The app now counts signature songs unless it filters `!Signature`.** Before this change, step 2 removed every play of any title a DJ played in more than half their shows.

A more clever way of identifying rows that are not song plays is needed since I don't have an unabridged list of song or artist name strings that are not actually songs.

*Status: done as a review loop.* The hard-coded filters moved to `config/non_song_patterns.csv`. Each run writes `data/non_song_candidates.csv`, a ranked list of strings that look like talk or web-page text, which you review; confirmed ones go into the patterns file. Nothing is removed automatically. Each pattern is tested against the field as scraped and against a plain form (letters of any script, digits, spaces; see `plain_text()`), so text decorated with symbols or combining marks, e.g. "╚ W̾e̾l̾c̾o̾m̾e̾ ̾T̾o̾ ̾R̾a̾d̾i̾o̾ ̾R̾a̾v̾i̾o̾l̾i̾ ⫸ ╗", or punctuated ("Irene Speaks!"), is still matched.

First review (September 2026) added patterns for:
- HTML social-media links
- `c("1995 Playlists"...` parser debris
- "View ... profile"
- a show note
- DJ talk ("... speaks", "Yr Dj Speeks", "Hysterica Talks", YA's "Jamie Jazz" segments)
- "via GIPHY"
- IB bumpers and stingers
- WA segments and pledge-drive entries
- FN intro/outro talk
- OB's "Welcome to Radio Ravioli"
- CL header text
- upper-case "MUSIC BEHIND DJ"
- dates entered as the artist

Together these removed 2,637 rows. A second pass, from step 3's distinctive-artist lists, added WFMU's phone number (201-209-9368 in any format), WA's "W/ Dan Morfitt" and "Joe Mcgasko's ..." segments, and a "taking a break while" show note (407 rows).

Other code efficiencies.

*Status: done.* Plain dplyr throughout (no switching between duckplyr and tibbles), cleaning steps as small functions, and one full rebuild per run (about 3 minutes).

### Files

| File | Role |
|---|---|
| `R/2 - clean_playlists.r` | Main script. Sections: settings, inputs, clean, outputs, candidate report, summary. |
| `R/func_clean_playlists.R` | `clean_playlists()` pipeline and its steps: `drop_non_songs()`, `make_artist_token()`, `condense_artist_tokens()`, `flag_signature_songs()`, `non_song_candidates()`. |
| `config/non_song_patterns.csv` | Non-song patterns: `field` (`Artist`, `Title` or `ArtistToken`), `pattern` (case-sensitive regex; whitespace is significant), `dj` (blank = all DJs), `note`. |

### Behaviour

- **Always a full rebuild from `playlists_raw`.** The old update mode cleaned only the new batch, so artist-token condensing and signature detection saw a few shows per DJ. On the September batch it stripped 10.9% of rows and emptied 3 shows. Step 2 no longer reads `playlists_temp`.
- **Pipeline order:**
  1. Record play order (`pos`).
  2. Drop one-row shows (empty-page markers) and duplicate rows.
  3. Apply the date cutoffs (before 1982; CL before 1997).
  4. Apply the `Artist` / `Title` non-song patterns; blank titles become "Unknown".
  5. Build `ArtistToken`: punctuation, parentheticals and "feat"/"with"/"live @" tails removed, first two words, title case, a few overrides such as Bowie and Yo La Tengo.
  6. Apply the `ArtistToken` patterns.
  7. Strip punctuation from `Title`, squish whitespace.
  8. Drop rows whose token is the DJ's `ShowToken`.
  9. Condense tokens to the most common artist spelling; ties go to the spelling that sorts first by bytes.
  10. Flag signature songs.
  11. Sort.
- **Play order is preserved.** The app's playlist tab orders a show's songs by parquet row number, so output is sorted by DJ, air date and play position. Position is `playlists_raw$Seq` (the song's position on the playlist page, recorded by 1b since Oct 2026). Rows from before then have `Seq = NA` and fall back to file order, which is NOT play order for most pre-2025 shows (about 75% of them don't even have contiguous rows), so signature detection is unreliable for them until they are re-scraped.
- **Share test for signatures (order-free):** a song (artist token + first 3 title words, near-identical artist tokens merged within DJ + title, e.g. "Bob Mcallister"/"Bob Mccallister") in more than `SIGNATURE_MIN_SHARE` (0.5) of a DJ's shows is a signature song, for DJs with 50+ shows and songs in 10+ shows. Every play of it is flagged. Threshold chosen by comparing show shares of run-flagged songs with all others (Oct 2026): above 0.5 nearly all unflagged songs were show themes or furniture. It misses signature songs used for only part of a DJ's history (e.g. MS's "Adios..."), which still rely on the run test.
- **Signature title matching:** consecutive openers/closers count as one song if they are equal after stripping version suffixes (mono, excerpt, intro...), or within 20% edit distance, comparing only the first k words when the shorter title has k >= 3 words ("Cherry Blossom Clinic" / "... Revisited"; "Auf Wiedershen" / "Auf Weidershen").
- **Missing titles:** 1,066 rows with an `NA` title (left by an old parser) are kept, as before.
- **Candidate report heuristics:**
  - `host_name`: the artist contains the host name from "Show with Host"
  - `keyword`: phrases rarely in song names (mic break, station ID, PSA, underwriting, promo, interview, intro/outro, jingle, bumper, stinger) in artist or title; "... speaks" in the artist; or a title that is only a common word (news, DJ, talk, traffic, weather, pledge, welcome, playlist...)
  - `long_text`: more than 8 words in the artist
  - `artist_is_title`
  - `page_text`: "Listener comments", "Your comment", "Javascript", "archived", links, "playlist"

  Long band names and self-titled songs dominate `long_text` and `artist_is_title`, so the report is for review only.

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `MIN_AIRDATE` | 1982-01-01 | Earlier dates are parse errors. |
| `CL_MIN_AIRDATE` | 1997-01-01 | CL's earlier dates are wrong. |
| `CONDENSE_ARTISTS` | `TRUE` | Replace tokens with the most common artist spelling. |
| `SIGNATURE_MIN_RUN` | `6` | Consecutive opening/closing shows for a signature song ("more than 5"). |
| `CANDIDATES_TOP_N` | `500` | Rows in the candidate report. |

### Outputs

| File | Contents |
|---|---|
| `data/playlists.parquet` | `DJ`, `AirDate`, `Artist`, `Title`, `ArtistToken`, `Signature` (new). Rows in play order within each show. |
| `data/all_artisttokens.rdata` | Sorted unique `ArtistToken` values. |
| `data/dj_key.parquet` | `showCount`, `FirstShow`, `LastShow` recomputed from the cleaned playlists. |
| `data/non_song_candidates.csv` | `Artist`, `Title`, `reason`, `plays`, `djs`, `example_dj`, `example_date`. |

### Testing

On 25 DJs (580,682 raw rows), with signature stripping turned off in the old code, old and new output are identical: 476,072 rows. The only difference found and fixed was the tie-break collation. All 12,238 shows keep play order.

### Open issues

- Web-page text that older parsers read as songs is in the patterns file ("Listener comments!", "Your comment:", "<-- Previous playlist", "Enable Javascript for more options!"). Removing it and the first-review patterns dropped 635 shows made up only of such text (116,405 to 115,770 shows).
- The app (`wfmu_explorer/app.R`) needs `filter(!Signature)` wherever signature songs should be left out.
- Backups from the first rebuild: `data/playlists_pre_step2.parquet`, `data/dj_key_pre_step2.parquet`.

## 3 - precalc_similarity.R

### Purpose

This script does 3 things.
1. Creates a similarity index for all pairs of DJs based on artists and songs in common.  It uses cosine distance.  More recent plays are given more weight.
2. Creates a list of songs which make each distinctive using TF-IDF
3. Pre renders a histogram of similiarity indices for whole station.

### Opportunities for improvement.

Is is there a better way to estimate similarity in this use case?

*Status (October 2026): refined, not replaced.* Cosine similarity on recency-weighted tf-idf vectors is a sound fit for "how alike are two DJs' playlists". Three changes:
- **Songs are keyed by artist + title.** Matching on title alone linked DJs through different songs that share a title: among titles more than one DJ plays, 73% of plays were on titles used by several artists ("untitled" by 2,565 artists, "interview", "side_a", "track_1").
- **Sublinear term frequency.** `log1p(count)`, so heavy rotation counts for less than proportionally. `1 + log(count)` is not used because recency weighting makes counts fall below 1.
- **Exclusions.** Signature and show-furniture plays (`Signature`) and the "Unknown" placeholder artist/title are left out.

Result: similarity ranks pairs almost as before (Spearman 0.96 against the previous file across 229,920 shared pairs), and the median DJ keeps 8 of their top 10 similar DJs.

Is TF-IDF the best way to measure distinctiveness?

*Status: replaced.* Distinctive artists now use weighted log-odds with an informative Dirichlet prior from station-wide counts (Monroe, Colaresi & Quinn 2008): each DJ's plays against the rest of the station, as a z-score. Unlike tf-idf it discounts artists played once or twice, so it is consistent across DJs with 10 and 2,000 shows. It favours artists a DJ plays a lot more than the station does (for WA, Bowie at 1,021 plays now ranks high). For DJs with very few shows every count is small and neither method says much.

Are there general code efficiencies to implement?

*Status: done.*
- Removed the unused `tm`, `vegan`, `lubridate` and duckplyr.
- Removed the read-back of the similarity file before plotting.
- Logic moved to small functions.
- Runtime about 1.3 minutes.

### Files

| File | Role |
|---|---|
| `R/3 - precalc_similiarity.r` | Main script: settings, inputs, similarity, distinctive artists, histogram. |
| `R/func_similarity.R` | `similarity_terms()`, `dj_cosine_similarity()`, `distinctive_artists()`, `similarity_histogram()`. |

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `HALF_LIFE_DAYS` | `365` | A play's weight halves every year before the latest show. |
| `ARTIST_WEIGHT`, `SONG_WEIGHT` | `1.5`, `1` | Relative weight of artist and song terms. |
| `MIN_TITLE_LENGTH` | `3` | Shorter titles (after removing punctuation) are not song terms. |
| `SUBLINEAR_TF` | `TRUE` | `log1p(count)` instead of `count`. |
| `DISTINCTIVE_N` | `100` | Distinctive artists kept per DJ. |

### Outputs

Formats unchanged; the app reads all three.

| File | Contents | How the app uses it |
|---|---|---|
| `data/djsimilarity.parquet` | `DJ1`, `DJ2`, `Similarity` for every ordered pair of different DJs, highest first. | Top 10 per DJ; pair lookup. |
| `data/distinctive_artists.parquet` | `DJ`, `ArtistToken`: top `DISTINCTIVE_N` per DJ, most distinctive first. | Shows every column except `DJ`, first 25 rows, so keep exactly these two columns in this order. |
| `data/similarity_histogram_gg.rdata` | ggplot `gg_sim`. | Keeps only `layer_data(gg_sim, 1)` and the x, y and title labels, cached as `sim_hist_bins.rds`. The app's caches are keyed on the newest file time in its `data/` folder, so they refresh by themselves when step 4 copies new files. |

Backups of the previous outputs: `data/*_pre_step3.*`.

### Open issues

- Talk rows found in distinctive-artist lists are now step 2 patterns: WFMU's phone number (201-209-9368 in any format), WA's "W/ Dan Morfitt" and "Joe Mcgasko's ..." segments, and a "taking a break while" note (407 rows).
- ~~The app also loads `data/djdtm.rdata` for its chord plot. It is a `tm` DocumentTermMatrix (478 DJs x 11,878 artist words) from December 2025 that no current script creates; 22 current DJs are missing from it. Step 3 could produce it.~~ *Done (October 2026).* `dj_artist_dtm()` in `R/func_similarity.R` builds the DTM from the current playlists; step 3 calls it and saves `data/djdtm.rdata`.

## 4 - save_files parquet.R

### Purpose

This script copies the files created in the previous steps to the folder where the shiny app that uses the data lives.

### Opportunities for improvement

Remove superfluous code.

*Status (October 2026): done.* The script now copies exactly the six files the app reads, checks that they exist first, and stops if a copy fails. Commented-out code, unused functions (`save_parquet_to_shiny`) and unused libraries are gone.

Two fixes:
- **DJ key:** the app reads `data/djKey.parquet`, but the old script copied `dj_key.parquet`, so the app's DJ key had not been updated since April 2026. The DJ key is now copied *as* `djKey.parquet`.
- **Copies use base `file.copy()`,** which gives them a new modification time. The app keys its caches on that time, so they refresh on the next start.

| Copied from `data/` | Name in `../wfmu_explorer/data/` |
|---|---|
| `playlists.parquet` | same |
| `djsimilarity.parquet` | same |
| `distinctive_artists.parquet` | same |
| `similarity_histogram_gg.rdata` | same |
| `dj_key.parquet` | `djKey.parquet` |
| `djdtm.rdata` | same (stale, see step 3 open issues) |

Files in the app's data folder that the app no longer reads: `dj_key.parquet`, `djKey.RData`, and `all_artisttokens.rdata` (read only by `wfmu_explorer/test.R`).

Delete obsolete data files not used by any of the scripts in the R folder.

*Status: listed, not deleted.* Scan of all scripts in `R/` (code only, not comments), October 2026:

| Group | Files |
|---|---|
| Used by the pipeline | `playlists_raw.parquet`, `playlists_temp.parquet`, `playlists.parquet`, `playlistURLs.parquet`, `wfmu_show_urls.rds`, `dj_profiles.rds`, `dj_music_status.rds`, `excluded_shows.rds`, `dj_key.parquet`, `djsimilarity.parquet`, `distinctive_artists.parquet`, `similarity_histogram_gg.rdata`, `all_artisttokens.rdata`, `non_song_candidates.csv`, `djdtm.rdata` |
| Used only by `get_pledges.R` | `pledge_info.rds`, `time_slots.rds` |
| Not used in `R/`, but used elsewhere in the project | `lastfm_tags.db` (594 MB) and `msd_summary_file.h5` (316 MB) by `dev/msd_tests.R`; `claylists.csv`, `claylists.parquet` by `dev/kenstuff.r` and `quarto/claylists_reports.qmd`; `playlists_dt.Rdata` by `dev/benchmark.R`; `bad_tables.rdata` by `dev/scrape_oneoffs.r` |
| Backups from this refactor (delete once satisfied) | `playlists_raw_backup.parquet`, `playlists_raw_pre_repair.parquet`, `playlists_pre_step2.parquet`, `dj_key_pre_step2.parquet`, `wfmu_show_urls_backup.rds`, `djsimilarity_pre_step3.parquet`, `distinctive_artists_pre_step3.parquet`, `similarity_histogram_gg_pre_step3.rdata` (about 400 MB) |
| Not referenced anywhere | `arts_data.zip`, `artistfreq.txt`, `city_pop.rdata`, `deaths.rdata`, `djDocs.RData`, `playlists_GK.rdata`, `GK_plURLs.rdata`, `efd_songs_disco.csv`, `efd_songs_PPPNW.csv`, `efd_songs_seventies.csv`, `test_pages.rds`, `dj_similarity_tidy.parquet`, `djKey_prelim.parquet`, `djtdm_all.RData`, `djtdm_off.RData`, `djtdm_on.RData`, `docMatrix.RData`, `docTermMatrix.RData` (about 40 MB) |

## Final Improvement

Move all the files you worked on in this project to a separate folder called wfmu_playlist_scrape, maintaining the project subfolder structure.