# Fetch and parse individual WFMU playlist pages into Artist/Title rows.
#
# Playlist pages come in many layouts accumulated over decades.
# parse_playlist() tries a sequence of parsers, most specific first, and
# returns the first non-empty result. Each parser returns a
# tibble(Artist, Title) or NULL.
#
# Requires: func_wfmu_http.R (safe_get_html, show_page_url).

# Header names used by older hand-made playlist tables, in priority order.
artist_header_names <- c("THE STOOGE", "Band", "Singer", "Artist", "artist", "ARTIST")
title_header_names <- c("THE SONG", "Track", "Song", "Title", "TITLE", "title")

safe_html_table <- purrr::possibly(rvest::html_table, otherwise = NULL)

first_line <- function(x) {
  stringr::str_split_i(as.character(x), "\\n", 1)
}

# Trim fields and drop rows missing either one. NULL if fewer than min_rows.
tidy_songs <- function(artist, title, min_rows = 1) {
  songs <- tibble::tibble(
    Artist = stringr::str_trim(artist),
    Title = stringr::str_trim(title)
  ) |>
    dplyr::filter(!is.na(Artist), !is.na(Title), Artist != "", Title != "")
  if (nrow(songs) < min_rows) NULL else songs
}

# ---------------------------------------------------------------------------
# Parsers, in the order they are tried

# 1. Modern pages: <td class="col_artist"> / <td class="col_song_title">.
#    Cells can contain extra links after an arrow; keep the text before it.
parse_col_classes <- function(doc) {
  artist_nodes <- rvest::html_elements(doc, "td.col_artist")
  title_nodes <- rvest::html_elements(doc, "td.col_song_title")
  if (length(artist_nodes) == 0 || length(artist_nodes) != length(title_nodes)) {
    return(NULL)
  }
  tidy_songs(
    artist = xml2::xml_text(artist_nodes, trim = TRUE) |>
      stringr::str_split_i("\u2192", 1),
    title = xml2::xml_text(title_nodes, trim = TRUE) |>
      stringr::str_split_i("\u2192|\n", 1)
  )
}

# Index of the first column whose name, or first-row value, exactly matches one
# of `candidates` (tried in priority order). Auto-named columns (X1, X2...)
# are ignored.
find_header_col <- function(col_names, first_row, candidates) {
  valid <- !stringr::str_detect(col_names, "^X\\d+$")
  for (name in candidates) {
    pattern <- stringr::regex(paste0("^", name, "$"), ignore_case = TRUE)
    idx <- which(
      (stringr::str_detect(col_names, pattern) |
        stringr::str_detect(first_row, pattern)) & valid
    )
    if (length(idx) > 0) {
      return(idx[1])
    }
  }
  NULL
}

# 2. Any table with recognisable Artist and Title headers.
parse_header_table <- function(tables) {
  header_pattern <- stringr::regex(
    paste(artist_header_names, collapse = "|"),
    ignore_case = TRUE
  )
  for (tbl in tables) {
    if (ncol(tbl) == 0 || nrow(tbl) < 2) next
    tbl <- tibble::as_tibble(tbl, .name_repair = "unique")
    first_row <- as.character(tbl[1, ])

    artist_col <- find_header_col(names(tbl), first_row, artist_header_names)
    title_col <- find_header_col(names(tbl), first_row, title_header_names)
    if (is.null(artist_col) || is.null(title_col)) next

    # skip the first row when it holds the header text
    start <- if (isTRUE(any(stringr::str_detect(first_row[artist_col], header_pattern)))) 2 else 1
    rows <- start:nrow(tbl)
    songs <- tidy_songs(
      first_line(tbl[[artist_col]][rows]),
      first_line(tbl[[title_col]][rows])
    )
    if (!is.null(songs)) {
      return(songs)
    }
  }
  parse_header_row_table(tables)
}

# 2b. Fallback for tables whose header sits below a note row, e.g. TT's
#     "Note: The music bed..." row above "Artist | Title | ...". Looks in the
#     first `max_header_row` rows for one cell matching an artist header and
#     another matching a title header, and takes songs from the rows below.
parse_header_row_table <- function(tables, max_header_row = 5) {
  match_col <- function(cells, candidates) {
    for (name in candidates) {
      idx <- which(stringr::str_detect(
        stringr::str_trim(cells),
        stringr::regex(paste0("^", name, "$"), ignore_case = TRUE)
      ))
      if (length(idx) > 0) return(idx[1])
    }
    NULL
  }
  for (tbl in tables) {
    if (ncol(tbl) < 2 || nrow(tbl) < 2) next
    for (r in seq_len(min(max_header_row, nrow(tbl) - 1))) {
      cells <- as.character(unlist(tbl[r, ]))
      artist_col <- match_col(cells, artist_header_names)
      title_col <- match_col(cells, title_header_names)
      if (is.null(artist_col) || is.null(title_col) || artist_col == title_col) next
      rows <- (r + 1):nrow(tbl)
      songs <- tidy_songs(
        first_line(tbl[[artist_col]][rows]),
        first_line(tbl[[title_col]][rows])
      )
      if (!is.null(songs)) {
        return(songs)
      }
    }
  }
  NULL
}

# 3. Headerless tables: assume the first two columns of one of the first two
#    tables are Artist and Title, if that gives 3+ varied rows.
parse_first_two_columns <- function(tables) {
  for (tbl in utils::head(tables, 2)) {
    if (ncol(tbl) < 2 || nrow(tbl) < 2) next
    songs <- tidy_songs(first_line(tbl[[1]]), first_line(tbl[[2]]), min_rows = 3)
    if (!is.null(songs) &&
      (dplyr::n_distinct(songs$Artist) > 1 || dplyr::n_distinct(songs$Title) > 1)) {
      return(songs)
    }
  }
  NULL
}

# 4. <td class="song"> cells holding "X - Y" in one string.
parse_td_song <- function(doc) {
  songs <- rvest::html_elements(doc, "td.song") |>
    xml2::xml_text(trim = TRUE) |>
    first_line() |>
    stringr::str_trim()
  songs <- songs[songs != "" & stringr::str_detect(songs, " - ")]
  if (length(songs) == 0) {
    return(NULL)
  }
  # Split order kept from the original scraper: "Title - Artist".
  parts <- stringr::str_split_fixed(songs, " - ", 2)
  tidy_songs(artist = parts[, 2], title = parts[, 1])
}

# 5. Second table, second column holds the whole playlist as
#    "Artist\n-\nTitle" entries separated by blank lines (e.g. DJ BK).
parse_single_column_table <- function(tables) {
  if (length(tables) < 2 || ncol(tables[[2]]) < 2 || nrow(tables[[2]]) == 0) {
    return(NULL)
  }
  cells <- as.character(tables[[2]][[2]])
  # with no playlist, the second table is often listener comments
  if (is.na(cells[1]) || stringr::str_detect(cells[1], "Listener")) {
    return(NULL)
  }
  entries <- paste(cells, collapse = "\n\n") |> stringr::str_split_1("\n\n")
  entries <- entries[entries != ""]
  parts <- stringr::str_split_fixed(entries, "\n-\n", 2)
  tidy_songs(
    artist = stringr::str_squish(parts[, 1]),
    title = stringr::str_replace_all(stringr::str_squish(parts[, 2]), '\\"', " ")
  )
}

# 6. No usable tables: plain-text lines "Artist : Title", 'Artist "Title"'
#    or "Artist | Title |" (e.g. DJs DK, BT).
parse_text_lines <- function(doc) {
  lines <- rvest::html_text(doc) |>
    stringr::str_split_1("\n") |>
    stringr::str_trim()

  playlist_lines <- lines[stringr::str_detect(lines, "^[A-Za-z ]+ : [A-Za-z ]+")]
  if (length(playlist_lines) == 0) {
    playlist_lines <- lines[stringr::str_detect(lines, '.+ \\".+\\"')]
  }
  # quoted strings inside JavaScript are not a playlist
  if (length(playlist_lines) > 0 && stringr::str_detect(playlist_lines[1], "window\\.open")) {
    playlist_lines <- character(0)
  }
  if (length(playlist_lines) == 0) {
    playlist_lines <- lines[stringr::str_detect(lines, ".+ \\|.+\\|")]
  }
  if (length(playlist_lines) == 0) {
    return(NULL)
  }
  # first two fields split on colon, quote or bar; the rest is dropped
  parts <- stringr::str_split_fixed(playlist_lines, ':|\\"|\\|', 3)
  tidy_songs(parts[, 1], parts[, 2])
}

playlist_parsers <- list(
  col_classes = \(doc, tables) parse_col_classes(doc),
  header_table = \(doc, tables) parse_header_table(tables()),
  first_two_columns = \(doc, tables) parse_first_two_columns(tables()),
  td_song = \(doc, tables) parse_td_song(doc),
  single_column_table = \(doc, tables) parse_single_column_table(tables()),
  text_lines = \(doc, tables) parse_text_lines(doc)
)

# ---------------------------------------------------------------------------
# Page-level functions

# Returns list(songs, method) from the first parser that finds songs, or NULL.
# Tables are only parsed if a table-based parser is reached.
parse_playlist <- function(doc) {
  table_cache <- NULL
  tables <- function() {
    if (is.null(table_cache)) {
      table_cache <<- rvest::html_elements(doc, "table") |>
        purrr::map(safe_html_table) |>
        purrr::compact()
    }
    table_cache
  }
  for (method in names(playlist_parsers)) {
    songs <- playlist_parsers[[method]](doc, tables)
    if (!is.null(songs)) {
      return(list(songs = songs, method = method))
    }
  }
  NULL
}

# Fetch a playlist page; framed legacy pages are replaced by their first frame.
fetch_playlist_doc <- function(url) {
  doc <- safe_get_html(url)
  if (is.null(doc)) {
    return(NULL)
  }
  frame_src <- rvest::html_elements(doc, "frame") |>
    rvest::html_attr("src") |>
    dplyr::first()
  if (!is.na(frame_src) && frame_src != "") {
    doc <- safe_get_html(xml2::url_absolute(frame_src, url))
  }
  doc
}

# Scrape one show. Returns DJ, AirDate, Seq, Artist, Title, method:
#   - songs found:  one row per song, method = parser name
#   - page parsed but no songs: one blank row (Artist = Title = ""), method =
#     "none". The blank row marks the show as scraped so it isn't retried.
#   - page could not be fetched: zero rows, so the show is retried next run.
# Seq is the song's position on the page (play order). It is stored because
# row order in parquet files is not reliable: older playlists_raw rows lost it.
scrape_playlist <- function(dj, air_date, show_id) {
  doc <- fetch_playlist_doc(show_page_url(show_id))
  if (is.null(doc)) {
    return(tibble::tibble(
      DJ = character(0), AirDate = as.Date(character(0)), Seq = integer(0),
      Artist = character(0), Title = character(0), method = character(0)
    ))
  }
  parsed <- parse_playlist(doc)
  if (is.null(parsed)) {
    return(tibble::tibble(
      DJ = dj, AirDate = air_date, Seq = 1L, Artist = "", Title = "", method = "none"
    ))
  }
  tibble::tibble(
    DJ = dj, AirDate = air_date, Seq = seq_len(nrow(parsed$songs)),
    parsed$songs, method = parsed$method
  )
}
