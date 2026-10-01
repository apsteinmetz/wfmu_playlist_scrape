# DJ similarity, distinctive artists and the similarity histogram.

# Make text safe for use inside a term name.
term_safe <- function(x) {
  x |>
    stringr::str_to_lower() |>
    stringr::str_replace_all("[^a-z0-9]+", "_") |>
    stringr::str_replace_all("^_|_$", "")
}

# Recency-weighted counts of artist and song terms per DJ.
# A play's weight halves every `half_life_days` before `ref_date`. Songs are
# keyed by artist token + title, so different songs that share a title
# ("Untitled", "Intro", "Side A") don't link DJs. Placeholder artists and
# titles ("Unknown") and all-digit artist tokens are not terms.
similarity_terms <- function(playlists, ref_date, half_life_days = 365,
                             artist_weight = 1.5, song_weight = 1,
                             min_title_length = 3) {
  plays <- playlists |>
    dplyr::filter(
      !is.na(ArtistToken), ArtistToken != "", ArtistToken != "Unknown",
      !stringr::str_detect(ArtistToken, "^[0-9]+$")
    ) |>
    dplyr::mutate(
      recency = 2^(-as.numeric(ref_date - AirDate) / half_life_days),
      artist_key = term_safe(ArtistToken),
      title_key = term_safe(dplyr::coalesce(Title, ""))
    )

  artists <- plays |>
    dplyr::transmute(DJ, term = paste0("artist_", artist_key), weight = recency * artist_weight)

  songs <- plays |>
    dplyr::filter(stringr::str_length(title_key) >= min_title_length, title_key != "unknown") |>
    dplyr::transmute(
      DJ,
      term = paste0("song_", artist_key, "__", title_key),
      weight = recency * song_weight
    )

  dplyr::bind_rows(artists, songs) |>
    dplyr::summarise(.by = c(DJ, term), weight_n = sum(weight))
}

# Cosine similarity between DJs on tf-idf term vectors.
# With sublinear = TRUE, tf = log1p(weighted count), so heavy rotation counts
# for less than proportionally (log1p rather than 1 + log because recency
# weighting makes counts fall below 1). idf = log(number of DJs / DJs using
# the term). Returns DJ1, DJ2, Similarity for every ordered pair of
# different DJs, highest similarity first.
dj_cosine_similarity <- function(terms, sublinear = TRUE) {
  n_djs <- dplyr::n_distinct(terms$DJ)
  weighted <- terms |>
    dplyr::mutate(
      tf = if (sublinear) log1p(weight_n) else weight_n,
      idf = log(n_djs / dplyr::n()),
      .by = term
    ) |>
    dplyr::mutate(w = tf * idf) |>
    dplyr::filter(w > 0)

  m <- tidytext::cast_sparse(weighted, DJ, term, w)
  djs <- rownames(m) # the Diagonal() product below drops dimnames
  norms <- sqrt(Matrix::rowSums(m^2))
  norms[norms == 0] <- 1
  m <- Matrix::Diagonal(x = 1 / norms) %*% m
  sim <- as.matrix(Matrix::tcrossprod(m))
  dimnames(sim) <- list(djs, djs)

  tibble::as_tibble(sim, rownames = "DJ1") |>
    tidyr::pivot_longer(-DJ1, names_to = "DJ2", values_to = "Similarity") |>
    dplyr::filter(DJ1 != DJ2) |>
    dplyr::arrange(dplyr::desc(Similarity))
}

# Artists that set each DJ apart: weighted log-odds of the DJ's plays versus
# the rest of the station, with an informative Dirichlet prior from
# station-wide counts (Monroe, Colaresi & Quinn 2008), as a z-score. Unlike
# tf-idf this discounts artists played only once or twice, so it behaves
# consistently for DJs with 10 shows and with 2,000. Returns the top `n`
# per DJ as DJ, ArtistToken, most distinctive first.
distinctive_artists <- function(playlists, n = 100) {
  counts <- playlists |>
    dplyr::filter(
      !is.na(ArtistToken), ArtistToken != "", ArtistToken != "Unknown",
      !stringr::str_detect(ArtistToken, "^[0-9]+$")
    ) |>
    dplyr::count(DJ, ArtistToken, name = "y")

  station <- dplyr::summarise(counts, .by = ArtistToken, alpha = sum(y))
  alpha0 <- sum(station$alpha)

  counts |>
    dplyr::left_join(station, by = "ArtistToken", relationship = "many-to-one") |>
    dplyr::mutate(n_dj = sum(y), .by = DJ) |>
    dplyr::mutate(
      y_rest = alpha - y,
      n_rest = alpha0 - n_dj,
      log_odds = log((y + alpha) / (n_dj + alpha0 - y - alpha)) -
        log((y_rest + alpha) / (n_rest + alpha0 - y_rest - alpha)),
      z = log_odds / sqrt(1 / (y + alpha) + 1 / (y_rest + alpha))
    ) |>
    dplyr::slice_max(z, n = n, by = DJ, with_ties = FALSE) |>
    dplyr::arrange(DJ, dplyr::desc(z)) |>
    dplyr::select(DJ, ArtistToken)
}

# DJ x artist-word count matrix for the app's chord plot, as a `tm`
# DocumentTermMatrix (rows = DJ codes). Follows the original recipe: all of a
# DJ's artist tokens split into lowercase words of 3+ letters (non-letters
# dropped, so "T-Model" becomes "tmodel"), raw counts, and only words used by
# more than (1 - sparse) of DJs, as tm::removeSparseTerms(sparse) does.
dj_artist_dtm <- function(playlists, sparse = 0.95) {
  words <- playlists |>
    dplyr::filter(!is.na(ArtistToken), ArtistToken != "", ArtistToken != "Unknown") |>
    dplyr::transmute(DJ, word = gsub("[^A-Za-z ]", "", ArtistToken)) |>
    tidyr::separate_longer_delim(word, " ") |>
    dplyr::mutate(word = tolower(word)) |>
    dplyr::filter(nchar(word) >= 3) |>
    dplyr::count(DJ, word)

  n_djs <- dplyr::n_distinct(words$DJ)
  words |>
    dplyr::filter(dplyr::n() > n_djs * (1 - sparse), .by = word) |>
    tidytext::cast_dtm(DJ, word, n)
}

# Histogram of all pairwise similarities. The app keeps only this layer's
# bins and the x, y and title labels.
similarity_histogram <- function(dj_similarity) {
  ggplot2::ggplot() +
    ggplot2::geom_histogram(
      data = dj_similarity,
      ggplot2::aes(Similarity, ggplot2::after_stat(count) + 1),
      color = "red",
      bins = 30
    ) +
    ggplot2::scale_y_log10(labels = function(x) format(x, scientific = FALSE)) +
    ggplot2::theme(
      axis.text = ggplot2::element_text(color = "white", size = 16),
      axis.title = ggplot2::element_text(color = "white", size = 16),
      panel.grid = ggplot2::element_blank(),
      plot.background = ggplot2::element_rect(fill = "black"),
      panel.background = ggplot2::element_rect(fill = "#337ab7")
    ) +
    ggplot2::labs(
      title = "Histogram of DJ Similarities",
      x = "Cosine Similarity Using Artist and Title",
      y = "DJ Pair Count (log scale)"
    )
}
