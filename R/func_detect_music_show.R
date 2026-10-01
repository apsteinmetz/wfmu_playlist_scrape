# Automatically decide whether a DJ hosts a music show.
#
# Every WFMU playlist page uses the same table layout regardless of show type,
# so the distinguishing signal is simply how many rows have an artist filled
# in. Talk / spoken-word shows have a handful at most (typically 0-3), while
# music shows have dozens. We sample a DJ's most recent playlists and compare
# the median artist count against a threshold.
#
# Requires: func_wfmu_http.R (safe_get_html, playlist_url).

# Number of non-empty artist cells on one playlist page. NA if unreachable.
count_playlist_songs <- function(show_id) {
  doc <- safe_get_html(show_page_url(show_id))
  if (is.null(doc)) {
    return(NA_integer_)
  }
  doc |>
    rvest::html_elements("td.col_artist") |>
    rvest::html_text2() |>
    stringr::str_squish() |>
    (\(x) sum(x != ""))()
}

# Classify DJs from the already-scraped playlists file, with no web requests.
# A show is one DJ + AirDate. DJs averaging more than `min_songs` rows per
# show are marked as music shows. Only positives come back: a DJ with few
# rows might just have sparse playlists, so those still get a live check.
music_status_from_playlists <- function(path = "data/playlists.parquet",
                                        min_songs = 5) {
  if (!file.exists(path)) {
    return(detect_music_shows(NULL, character(0)))
  }
  arrow::open_dataset(path) |>
    dplyr::count(DJ, AirDate) |>
    dplyr::group_by(DJ) |>
    dplyr::summarise(n_checked = dplyr::n(), median_songs = mean(n)) |>
    dplyr::collect() |>
    dplyr::filter(median_songs > min_songs) |>
    dplyr::mutate(
      n_checked = as.integer(n_checked),
      music_show = TRUE,
      checked_on = Sys.Date()
    )
}

# Classify `djs` using their `n_shows` most recent entries in `show_urls`
# (a data frame with columns DJ, AirDate, show_id).
#
# Returns one row per DJ:
#   DJ, n_checked, median_songs, music_show, checked_on
# DJs with no playlist URLs at all get music_show = FALSE, which mirrors the
# old behaviour of excluding DJs whose playlists couldn't be found.
detect_music_shows <- function(show_urls, djs, n_shows = 3, min_songs = 5) {
  djs <- unique(djs)
  if (length(djs) == 0) {
    return(tibble::tibble(
      DJ = character(0),
      n_checked = integer(0),
      median_songs = numeric(0),
      music_show = logical(0),
      checked_on = as.Date(character(0))
    ))
  }

  message("Checking music/talk status for ", length(djs), " DJ(s)...")

  # Playlist pages exist before a show airs and are empty until then, so only
  # sample shows that have already aired.
  sampled <- show_urls |>
    dplyr::filter(DJ %in% djs, AirDate <= Sys.Date(), !is_dj_page(show_id)) |>
    dplyr::arrange(DJ, dplyr::desc(AirDate)) |>
    dplyr::slice_head(n = n_shows, by = DJ) |>
    dplyr::mutate(n_songs = purrr::map_int(show_id, count_playlist_songs)) |>
    dplyr::summarise(
      .by = DJ,
      n_checked = dplyr::n(),
      median_songs = stats::median(n_songs, na.rm = TRUE)
    )

  tibble::tibble(DJ = djs) |>
    dplyr::left_join(sampled, by = "DJ") |>
    dplyr::mutate(
      n_checked = dplyr::coalesce(n_checked, 0L),
      music_show = !is.na(median_songs) & median_songs >= min_songs,
      checked_on = Sys.Date()
    )
}
