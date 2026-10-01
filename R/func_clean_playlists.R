# Clean playlists_raw into the canonical playlists table.
#
# clean_playlists() runs the steps below in order. Row order within each show
# is play order: it is captured from playlists_raw as `pos` and restored at
# the end, because the Shiny app orders a show's songs by parquet row number.

# ---------------------------------------------------------------------------
# Non-song rows

# Patterns file: field (Artist, Title or ArtistToken), pattern (regex,
# case-sensitive), dj (blank = all DJs), note. Whitespace is significant.
read_non_song_patterns <- function(path) {
  readr::read_csv(
    path,
    col_types = readr::cols(.default = readr::col_character()),
    trim_ws = FALSE,
    na = character()
  )
}

# Text reduced to letters (any script), digits and spaces. Some entries are
# decorated with combining marks ("W̾e̾l̾c̾o̾m̾e̾") or symbols ("✿ ✿ ✿ Welcome"),
# sometimes mis-encoded ("wÌ¾eÌ¾"), which hides words from a regex.
plain_text <- function(x) {
  x <- iconv(x, "UTF-8", "UTF-8", sub = "")
  x <- gsub("\\p{M}", "", x, perl = TRUE)
  # combining marks whose UTF-8 bytes were read as Latin-1
  x <- gsub("\u00cc[\u0080-\u00bf]", "", x, perl = TRUE)
  stringr::str_squish(gsub("[^\\p{L}\\p{N} ]", "", x, perl = TRUE))
}

# Drop rows matching any pattern whose field is in `fields`. Each pattern is
# tested against the field as scraped and against its plain_text() form.
drop_non_songs <- function(playlists, patterns, fields) {
  pats <- dplyr::filter(patterns, field %in% fields)
  plain <- purrr::map(rlang::set_names(unique(pats$field)), \(f) plain_text(playlists[[f]]))
  drop <- logical(nrow(playlists))
  for (i in seq_len(nrow(pats))) {
    f <- pats$field[i]
    hit <- grepl(pats$pattern[i], playlists[[f]]) | grepl(pats$pattern[i], plain[[f]])
    if (pats$dj[i] != "") hit <- hit & playlists$DJ == pats$dj[i]
    drop <- drop | hit
  }
  playlists[!drop, ]
}

# ---------------------------------------------------------------------------
# Artist tokens

# Well-known artists shortened to one word, or kept at three.
artist_token_overrides <- c(
  "Ennio Morricone" = "Morricone",
  "David Bowie" = "Bowie",
  "Bob Dylan" = "Dylan",
  "Elvis Presley" = "Elvis",
  "Yo La" = "Yo La Tengo",
  "Guided By" = "Guided By Voices"
)

# Normalise an artist name to a short token: punctuation, parentheticals,
# "featuring"/"with"/"live @" tails and filler words removed, then the first
# two words in title case.
make_artist_token <- function(artist) {
  x <- artist
  # names that are all punctuation
  x <- gsub("^!!!$", "chkchkchk", x)
  x <- gsub("^\\.\\.\\.$", "Unknown", x)
  x <- gsub("Uknown", "Unknown", x)
  x <- gsub("^\\? \\&", "Question Mark And ", x)
  x <- gsub("^\\? And", "Question Mark And ", x)
  x <- gsub("\\&", " ", x)
  x <- gsub("\\([^()]+\\)", "", x)
  x <- tolower(x)
  # "Versus" is a band name, so only "vs" is removed
  x <- gsub("(feat |featuring |and the |with |vs |vs\\.).+", "", x)
  x <- gsub("(live @ |live on|@).+", "", x)
  x <- gsub("[^A-Za-z0-9 ]", "", x)
  x <- gsub("(interview w|interview)", "", x)
  x <- gsub("unknown artist(s| )|unknown", "Unknown", x)
  x <- gsub("various artists|various", "Unknown", x)
  # many band names start with these
  x <- gsub("new york", "newyork", x)
  x <- gsub("x ray", "xray", x)
  x <- gsub("and | of | the ", " ", x)
  x <- gsub("^the ", " ", x)
  x <- stringr::str_to_title(stringr::str_squish(x))
  x <- sub("^\\s*(\\S+(?:\\s+\\S+){0,1}).*$", "\\1", x, perl = TRUE)
  for (from in names(artist_token_overrides)) {
    x <- gsub(from, artist_token_overrides[[from]], x, fixed = TRUE)
  }
  x <- gsub("Unkown", "Unknown", x)
  x <- gsub("^$", "Unknown", x)
  x
}

# Replace each token with the most common spelling of the artist it came from,
# without a leading/trailing "The". Ties go to the spelling that sorts first
# by bytes (uppercase before lowercase), independent of locale.
condense_artist_tokens <- function(playlists) {
  token_map <- playlists |>
    dplyr::count(ArtistToken, Artist, name = "plays") |>
    dplyr::filter(plays == max(plays), .by = ArtistToken) |>
    dplyr::summarise(.by = ArtistToken, base_artist = sort(Artist, method = "radix")[1]) |>
    dplyr::mutate(base_artist = gsub("^[Tt]he |, [Tt]he$", "", base_artist))

  playlists |>
    dplyr::left_join(token_map, by = "ArtistToken", relationship = "many-to-one") |>
    dplyr::mutate(ArtistToken = dplyr::coalesce(base_artist, ArtistToken)) |>
    dplyr::select(-base_artist)
}

# ---------------------------------------------------------------------------
# Signature songs

# Title key for signature runs: version suffixes are ignored, so
# "In The Courtyard Of The Stars Mono" and "... Stereo Mix" count as one song.
# Titles have already lost their punctuation, so "(Mono)" arrives as " Mono".
version_suffix <- paste0(
  "\\s+(mono|stereo|mix|version|remaster|remastered|single|edit|radio|album|",
  "(19|20)\\d{2})$"
)

signature_title_key <- function(title) {
  key <- stringr::str_squish(tolower(title))
  repeat {
    stripped <- sub(version_suffix, "", key)
    if (identical(stripped, key)) break
    key <- stripped
  }
  key
}

# A signature song opens (or closes) at least `min_run` consecutive shows by a
# DJ. Signature = TRUE marks only the opening (or closing) plays inside such a
# run. The same song opening a show outside the run, or played mid-show, is
# not flagged, so a DJ can adopt and drop signature songs over time.
# Needs `pos`.
flag_signature_songs <- function(playlists, min_run = 6) {
  playlists <- playlists |>
    dplyr::mutate(
      is_open = pos == min(pos),
      is_close = pos == max(pos),
      .by = c(DJ, AirDate)
    )

  # shows whose opener / closer belongs to a qualifying run
  run_shows <- playlists |>
    dplyr::filter(is_open | is_close) |>
    dplyr::summarise(
      .by = c(DJ, AirDate),
      open = signature_title_key(Title[which.min(pos)]),
      close = signature_title_key(Title[which.max(pos)])
    ) |>
    tidyr::pivot_longer(c(open, close), names_to = "slot", values_to = "title_key") |>
    dplyr::arrange(DJ, slot, AirDate) |>
    dplyr::mutate(run_id = dplyr::consecutive_id(title_key), .by = c(DJ, slot)) |>
    dplyr::filter(
      dplyr::n() >= min_run,
      !is.na(title_key), !title_key %in% c("", "unknown"),
      .by = c(DJ, slot, run_id)
    )

  open_runs <- run_shows |>
    dplyr::filter(slot == "open") |>
    dplyr::transmute(DJ, AirDate, in_open_run = TRUE)
  close_runs <- run_shows |>
    dplyr::filter(slot == "close") |>
    dplyr::transmute(DJ, AirDate, in_close_run = TRUE)

  playlists |>
    dplyr::left_join(open_runs, by = c("DJ", "AirDate"), relationship = "many-to-one") |>
    dplyr::left_join(close_runs, by = c("DJ", "AirDate"), relationship = "many-to-one") |>
    dplyr::mutate(
      Signature = (is_open & dplyr::coalesce(in_open_run, FALSE)) |
        (is_close & dplyr::coalesce(in_close_run, FALSE)) |
        (dplyr::coalesce(stringr::str_detect(Title, show_furniture_pattern), FALSE) &
          !dplyr::coalesce(stringr::str_detect(Title, bare_intro_pattern), FALSE))
    ) |>
    dplyr::select(-is_open, -is_close, -in_open_run, -in_close_run)
}

# Recordings used as show furniture (intros, jingles, promos...) are flagged
# like signature songs wherever they are played. Bare "theme" and "open" are
# not used: they match real songs ("Theme From Shaft", "Wide Open"). "Jingle
# Bells"/"Jingle Jangle" and promo pressings ("promo single", "promo mix") are
# songs, not furniture.
show_furniture_pattern <- stringr::regex(
  paste0(
    "\\b(intro|outro|psa|public service announcement|bumper|stinger|",
    "theme song|opening theme|closing theme|show open|",
    "jingle(?! ?(bells?|jangle|jingle))|",
    "promo(?! ?(single|mix|version|edit|45|copy)))\\b"
  ),
  ignore_case = TRUE
)

# A title that is only "Intro" (or "Intro 2") is usually an album track, not a
# show intro, so it is not flagged. "Testify Intro" still is.
bare_intro_pattern <- stringr::regex("^\\s*intro(\\s+\\d+)?\\s*$", ignore_case = TRUE)

# ---------------------------------------------------------------------------
# Pipeline

clean_playlists <- function(raw, dj_key, patterns,
                            min_airdate = as.Date("1982-01-01"),
                            cl_min_airdate = as.Date("1997-01-01"),
                            condense_artists = TRUE,
                            signature_min_run = 6) {
  show_tokens <- dj_key |>
    dplyr::filter(!is.na(ShowToken)) |>
    dplyr::distinct(DJ, ArtistToken = ShowToken)

  playlists <- raw |>
    # play order within a show, from file order
    dplyr::mutate(pos = dplyr::row_number(), .by = c(DJ, AirDate)) |>
    # one-row shows are empty-page markers or fragments
    dplyr::filter(dplyr::n() > 1, .by = c(DJ, AirDate)) |>
    dplyr::distinct(DJ, AirDate, Artist, Title, .keep_all = TRUE) |>
    # dates before 1982 are parse errors (only Diane "Kamikaze" goes back to
    # the '80s); CL's pre-1997 dates are bad too
    dplyr::filter(AirDate > min_airdate, !(DJ == "CL" & AirDate < cl_min_airdate)) |>
    drop_non_songs(patterns, c("Artist", "Title")) |>
    dplyr::filter(Artist != "") |>
    dplyr::mutate(
      Title = dplyr::if_else(Title == "", "Unknown", Title),
      ArtistToken = make_artist_token(Artist)
    ) |>
    dplyr::filter(nchar(ArtistToken) < 100) |>
    drop_non_songs(patterns, "ArtistToken") |>
    dplyr::mutate(Title = gsub("[^A-Za-z0-9 ]", "", Title)) |>
    dplyr::distinct(DJ, AirDate, Artist, Title, ArtistToken, .keep_all = TRUE) |>
    dplyr::mutate(
      Artist = gsub("\\s+", " ", Artist),
      Title = gsub("\\s+", " ", Title)
    ) |>
    # the DJ's own show name showing up as an artist
    dplyr::anti_join(show_tokens, by = c("DJ", "ArtistToken"))

  if (condense_artists) {
    playlists <- condense_artist_tokens(playlists)
  }

  playlists |>
    flag_signature_songs(min_run = signature_min_run) |>
    dplyr::arrange(DJ, AirDate, pos) |>
    dplyr::select(DJ, AirDate, Artist, Title, ArtistToken, Signature)
}

# ---------------------------------------------------------------------------
# Candidate report

# Rows that look like talk rather than songs, for review. Nothing is removed:
# confirmed patterns go into the non-song patterns file.
# Phrases rarely found in song or band names...
non_song_keywords <- stringr::regex(
  paste0(
    "\\b(mic break|station id|psa|public service announcement|underwriting|",
    "promo|interview|announcement|call[- ]?in|intro|outro|",
    "bumper|stinger|jingle)\\b"
  ),
  ignore_case = TRUE
)
# ...talk markers that only mean talk in the Artist field ("Action Speaks
# Louder" is a song)...
non_song_artist_keywords <- stringr::regex("\\b(speaks|speeks)$", ignore_case = TRUE)
# ...and common words that only count when they are the whole Title (as parts
# of names they match Traffic, Talk Talk, DJ Shadow, "Stormy Weather" etc.).
non_song_whole_words <- c(
  "news", "dj", "talk", "traffic", "weather", "host", "commercial", "pledge",
  "marathon", "intro", "outro", "welcome", "playlist"
)

page_text_pattern <- stringr::regex(
  "listener comments|your comment|no html|javascript|playlist|archived|pop-up|listen:|http|www\\.",
  ignore_case = TRUE
)

non_song_candidates <- function(playlists, dj_key, top_n = 500) {
  # host name from "Show Name with Host"; short names match too much
  hosts <- dj_key |>
    dplyr::transmute(DJ, host = stringr::str_match(ShowName, "(?i) with (.+)$")[, 2]) |>
    dplyr::filter(!is.na(host), nchar(host) >= 4)

  playlists |>
    dplyr::left_join(hosts, by = "DJ") |>
    dplyr::mutate(
      Title = dplyr::coalesce(Title, ""),
      host_name = !is.na(host) &
        stringr::str_detect(tolower(Artist), stringr::fixed(tolower(dplyr::coalesce(host, "\u0001")))),
      keyword = stringr::str_detect(Artist, non_song_keywords) |
        stringr::str_detect(Title, non_song_keywords) |
        stringr::str_detect(Artist, non_song_artist_keywords) |
        tolower(stringr::str_squish(Title)) %in% non_song_whole_words,
      long_text = stringr::str_count(Artist, "\\S+") > 8,
      artist_is_title = !Title %in% c("", "Unknown") & tolower(Artist) == tolower(Title),
      # web-page text read as a song, e.g. "Listener comments!"
      page_text = stringr::str_detect(Artist, page_text_pattern)
    ) |>
    dplyr::filter(host_name | keyword | long_text | artist_is_title | page_text) |>
    dplyr::mutate(
      reason = paste(
        c("host_name", "keyword", "long_text", "artist_is_title", "page_text")[
          c(host_name[1], keyword[1], long_text[1], artist_is_title[1], page_text[1])
        ],
        collapse = "+"
      ),
      .by = c(Artist, Title, host_name, keyword, long_text, artist_is_title, page_text)
    ) |>
    dplyr::summarise(
      .by = c(Artist, Title, reason),
      plays = dplyr::n(),
      djs = dplyr::n_distinct(DJ),
      example_dj = dplyr::first(DJ),
      example_date = dplyr::first(AirDate)
    ) |>
    dplyr::arrange(dplyr::desc(plays)) |>
    dplyr::slice_head(n = top_n)
}
