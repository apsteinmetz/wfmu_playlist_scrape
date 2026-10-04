# Clean playlists_raw into the canonical playlists table.
#
# Requires: func_progress.R (progress(), fmt_n()).
#
# clean_playlists() runs the steps below in order. Play order within each show
# is captured as `pos` and restored at the end, because the Shiny app orders a
# show's songs by parquet row number. `pos` is playlists_raw$Seq (position on
# the playlist page); rows scraped before Seq existed fall back to file order,
# which for most pre-2025 shows is NOT play order.

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
  "(\\s+(mono|stereo|mix|version|remaster|remastered|single|edit|radio|album|",
  "excerpt|intro|outro|theme|(19|20)\\d{2}))+$"
)

signature_title_key <- function(title) {
  sub(version_suffix, "", stringr::str_squish(tolower(title)), perl = TRUE)
}

# TRUE where two title keys look like the same recording, allowing for the
# ways DJs vary furniture titles:
#   - misspellings: edit distance at most `max_dist` of the longer key
#     ("Auf Wiedershen" / "Auf Weidershen" / "Auf Wiedersehn")
#   - added tails: when the shorter key has `min_prefix_words`+ words, the
#     longer one is cut to the same number of words before comparing
#     ("Cherry Blossom Clinic" / "Cherry Blossom Clinic Revisited")
# Junk keys ("", "unknown") never match.
signature_titles_match <- function(a, b, max_dist = 0.2, min_prefix_words = 3) {
  junk <- c("", "unknown")
  ok <- !is.na(a) & !is.na(b) & !a %in% junk & !b %in% junk
  same <- ok & a == b
  check <- which(ok & !same)
  if (length(check) == 0) {
    return(same)
  }
  a <- a[check]
  b <- b[check]
  k <- pmin(stringr::str_count(a, "\\S+"), stringr::str_count(b, "\\S+"))
  trunc <- k >= min_prefix_words
  a[trunc] <- stringr::word(a[trunc], 1, k[trunc])
  b[trunc] <- stringr::word(b[trunc], 1, k[trunc])
  d <- mapply(\(x, y) utils::adist(x, y)[1, 1], a, b, USE.NAMES = FALSE)
  same[check] <- d <= max_dist * pmax(nchar(a), nchar(b))
  same
}

# First three words of a title key: DJs vary the tail of furniture titles
# ("Cherry Blossom Clinic" / "... Revisited").
signature_short_title <- function(title) {
  sub("^(\\S+(?: \\S+){0,2}).*$", "\\1", signature_title_key(title), perl = TRUE)
}

# Canonical spelling for near-identical artist tokens ("Bob Mcallister" /
# "Bob Mccallister"): tokens within `max_dist` edit distance (relative to the
# longer one, case-insensitive) are chained into one cluster, which takes the
# most-played spelling. Meant for the tokens of one DJ + title.
merge_artist_variants <- function(tokens, plays, max_dist = 0.2) {
  if (length(tokens) < 2) {
    return(tokens)
  }
  low <- tolower(tokens)
  rel <- utils::adist(low) / outer(nchar(low), nchar(low), pmax)
  cl <- stats::cutree(stats::hclust(stats::as.dist(rel), method = "single"), h = max_dist)
  canon <- tapply(seq_along(tokens), cl, \(i) tokens[i][which.max(plays[i])])
  unname(canon[as.character(cl)])
}

# Share-test exclusions file: dj, title, artist (optional), note. Lines
# starting with # are comments. A missing file means no exclusions.
read_share_exclusions <- function(path) {
  empty <- tibble::tibble(dj = character(), title = character(),
                          artist = character(), note = character())
  if (is.null(path) || !file.exists(path)) {
    return(empty)
  }
  ex <- readr::read_csv(
    path,
    col_types = readr::cols(.default = readr::col_character()),
    comment = "#", na = character()
  )
  dplyr::bind_rows(empty, ex)
}

# Manual signature songs file: dj, title_pattern, artist_pattern (optional),
# note. Lines starting with # are comments. A missing file means none.
read_signature_includes <- function(path) {
  empty <- tibble::tibble(dj = character(), title_pattern = character(),
                          artist_pattern = character(), note = character())
  if (is.null(path) || !file.exists(path)) {
    return(empty)
  }
  inc <- readr::read_csv(
    path,
    col_types = readr::cols(.default = readr::col_character()),
    comment = "#", na = character()
  )
  dplyr::bind_rows(empty, inc)
}

# Logical vector, one per row: TRUE for plays matching an include entry (same
# DJ, title regex, and artist regex if given; all case-insensitive). Entries
# matching nothing are reported.
include_signature_rows <- function(playlists, includes = NULL) {
  hit <- logical(nrow(playlists))
  if (is.null(includes) || nrow(includes) == 0) {
    return(hit)
  }
  unused <- character()
  for (i in seq_len(nrow(includes))) {
    artist_pat <- dplyr::coalesce(includes$artist_pattern[i], "")
    m <- playlists$DJ == includes$dj[i] &
      dplyr::coalesce(stringr::str_detect(
        playlists$Title, stringr::regex(includes$title_pattern[i], ignore_case = TRUE)
      ), FALSE)
    if (artist_pat != "") {
      m <- m & dplyr::coalesce(stringr::str_detect(
        playlists$Artist, stringr::regex(artist_pat, ignore_case = TRUE)
      ), FALSE)
    }
    if (!any(m)) unused <- c(unused, paste0(includes$dj[i], " \"", includes$title_pattern[i], "\""))
    hit <- hit | m
  }
  if (length(unused) > 0) {
    message("Signature includes matching no plays: ", paste(unused, collapse = ", "))
  }
  hit
}

# Share test, for shows whose play order is unknown: a song (artist + first
# three title words, artist spellings merged) in more than `min_share` of a
# DJ's shows, played in at least `min_plays` shows, by a DJ with at least
# `min_shows` shows. Songs listed in `exclusions` (see read_share_exclusions())
# are never flagged by this test. Returns a logical vector, one per row: every
# play of such a song is flagged, wherever it falls in the show.
share_signature_rows <- function(playlists, min_share = 0.5, min_shows = 50,
                                 min_plays = 10, max_artist_dist = 0.2,
                                 exclusions = NULL) {
  titles <- unique(playlists$Title)
  short <- signature_short_title(titles)
  songs <- playlists |>
    dplyr::transmute(
      .row = dplyr::row_number(), DJ, AirDate, ArtistToken,
      title_short = short[match(Title, titles)]
    ) |>
    dplyr::mutate(n_shows = dplyr::n_distinct(AirDate), .by = DJ) |>
    dplyr::filter(
      n_shows >= min_shows,
      !is.na(title_short), !title_short %in% c("", "unknown")
    )

  # only DJ + title groups that could reach min_plays need merging
  # vctrs counting and group ids: dplyr::count() (which sorts) and per-group
  # dplyr expressions are slow with ~1.5M DJ + title groups
  artist_map <- vctrs::vec_count(songs[c("DJ", "title_short", "ArtistToken")], sort = "none")
  artist_map <- tibble::tibble(artist_map$key, plays = artist_map$count)
  grp <- vctrs::vec_group_id(artist_map[c("DJ", "title_short")])
  artist_map$total <- rowsum(artist_map$plays, grp, reorder = TRUE)[grp]
  artist_map$n_artists <- tabulate(grp)[grp]
  artist_map <- dplyr::filter(artist_map, total >= min_plays)
  artist_map <- dplyr::bind_rows(
    artist_map |>
      dplyr::filter(n_artists == 1) |>
      dplyr::mutate(artist_key = ArtistToken),
    artist_map |>
      dplyr::filter(n_artists > 1) |>
      dplyr::mutate(
        artist_key = merge_artist_variants(ArtistToken, plays, max_artist_dist),
        .by = c(DJ, title_short)
      )
  ) |>
    dplyr::select(DJ, title_short, ArtistToken, artist_key)

  songs <- dplyr::inner_join(songs, artist_map, by = c("DJ", "title_short", "ArtistToken"))
  song_shows <- songs |>
    dplyr::distinct(DJ, title_short, artist_key, AirDate, n_shows) |>
    dplyr::select(-AirDate) |>
    vctrs::vec_count(sort = "none")
  signature_keys <- tibble::tibble(song_shows$key, shows_played = song_shows$count) |>
    dplyr::filter(shows_played >= min_plays, shows_played / n_shows > min_share)

  if (!is.null(exclusions) && nrow(exclusions) > 0) {
    # titles are normalised as in clean_playlists(); a match needs one key to
    # be a whole-word prefix of the other ("boyfriend application" matches an
    # entry written "Boyfriend Application (live)")
    excluded <- exclusions |>
      dplyr::transmute(
        .ex = dplyr::row_number(), DJ = dj,
        ex_title = signature_short_title(gsub("[^A-Za-z0-9 ]", "", title)),
        artist = tolower(stringr::str_squish(dplyr::coalesce(artist, "")))
      ) |>
      dplyr::inner_join(signature_keys, by = "DJ", relationship = "many-to-many") |>
      dplyr::filter(
        startsWith(paste0(ex_title, " "), paste0(title_short, " ")) |
          startsWith(paste0(title_short, " "), paste0(ex_title, " ")),
        # blank artist = any artist ("\u0001" avoids an empty search pattern)
        artist == "" | stringr::str_detect(
          tolower(artist_key), stringr::fixed(dplyr::if_else(artist == "", "\u0001", artist))
        )
      )
    unused <- setdiff(seq_len(nrow(exclusions)), excluded$.ex)
    if (length(unused) > 0) {
      message(
        "Share-test exclusions matching no flagged song: ",
        paste0(exclusions$dj[unused], " \"", exclusions$title[unused], "\"", collapse = ", ")
      )
    }
    signature_keys <- dplyr::anti_join(
      signature_keys, excluded, by = c("DJ", "title_short", "artist_key")
    )
  }

  flagged <- dplyr::semi_join(songs, signature_keys, by = c("DJ", "title_short", "artist_key"))

  seq_len(nrow(playlists)) %in% flagged$.row
}

# Signature = TRUE if any of these hold:
#   - Run test: the song opens (or closes) at least `min_run` consecutive shows
#     by a DJ. Consecutive titles count as the same song if
#     signature_titles_match() says so. Only the opening (or closing) plays
#     inside the run are flagged, so a DJ can adopt and drop signature songs
#     over time. Needs `pos`, so it only works where play order is known.
#   - Share test: share_signature_rows(), which ignores play order.
#   - Manual includes: include_signature_rows().
#   - Show furniture titles (show_furniture_pattern).
flag_signature_songs <- function(playlists, min_run = 6, min_share = 0.5,
                                 share_min_shows = 50, share_min_plays = 10,
                                 share_exclusions = NULL, includes = NULL) {
  progress("  Signature share test")
  share_sig <- share_signature_rows(
    playlists,
    min_share = min_share, min_shows = share_min_shows, min_plays = share_min_plays,
    exclusions = share_exclusions
  )
  progress("  Signature includes")
  share_sig <- share_sig | include_signature_rows(playlists, includes)

  progress("  Signature run test")
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
    dplyr::mutate(
      run_id = cumsum(!signature_titles_match(title_key, dplyr::lag(title_key))),
      .by = c(DJ, slot)
    ) |>
    dplyr::filter(
      dplyr::n() >= min_run,
      !is.na(title_key), !title_key %in% c("", "unknown"),
      .by = c(DJ, slot, run_id)
    )

  progress("  Signature furniture titles and combining flags")
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
        share_sig |
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
                            signature_min_run = 6,
                            signature_min_share = 0.5,
                            signature_share_min_shows = 50,
                            signature_share_min_plays = 10,
                            signature_share_exclusions = NULL,
                            signature_includes = NULL) {
  show_tokens <- dj_key |>
    dplyr::filter(!is.na(ShowToken)) |>
    dplyr::distinct(DJ, ArtistToken = ShowToken)

  if (!"Seq" %in% names(raw)) raw$Seq <- NA_integer_

  progress("Ordering and de-duplicating ", fmt_n(nrow(raw)), " raw rows")
  playlists <- raw |>
    # play order within a show: page position, else file order (legacy rows)
    dplyr::mutate(pos = dplyr::coalesce(Seq, dplyr::row_number()), .by = c(DJ, AirDate)) |>
    # so distinct() below keeps the earliest play of a repeated song
    dplyr::arrange(DJ, AirDate, pos) |>
    # one-row shows are empty-page markers or fragments
    dplyr::filter(dplyr::n() > 1, .by = c(DJ, AirDate)) |>
    dplyr::distinct(DJ, AirDate, Artist, Title, .keep_all = TRUE) |>
    # dates before 1982 are parse errors (only Diane "Kamikaze" goes back to
    # the '80s); CL's pre-1997 dates are bad too
    dplyr::filter(AirDate > min_airdate, !(DJ == "CL" & AirDate < cl_min_airdate))

  progress("Dropping non-song rows by Artist/Title (", fmt_n(nrow(playlists)), " rows)")
  playlists <- drop_non_songs(playlists, patterns, c("Artist", "Title"))

  progress("Making artist tokens (", fmt_n(nrow(playlists)), " rows)")
  playlists <- playlists |>
    dplyr::filter(Artist != "") |>
    dplyr::mutate(
      Title = dplyr::if_else(Title == "", "Unknown", Title),
      ArtistToken = make_artist_token(Artist)
    ) |>
    dplyr::filter(nchar(ArtistToken) < 100)

  progress("Dropping non-song rows by ArtistToken and tidying titles")
  playlists <- playlists |>
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
    progress("Condensing artist tokens (", fmt_n(nrow(playlists)), " rows)")
    playlists <- condense_artist_tokens(playlists)
  }

  progress("Flagging signature songs")
  playlists |>
    flag_signature_songs(
      min_run = signature_min_run,
      min_share = signature_min_share,
      share_min_shows = signature_share_min_shows,
      share_min_plays = signature_share_min_plays,
      share_exclusions = signature_share_exclusions,
      includes = signature_includes
    ) |>
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
