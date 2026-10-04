# Scrape one DJ's landing page(s) for playlist links and profile info.
#
# A DJ page (e.g. https://www.wfmu.org/playlists/AQ) lists the current
# season's playlists plus links to prior-year pages (AQ2025, AQ2024, ...).
# Each prior-year page has the same layout, so the same parser handles both.
#
# Requires: func_wfmu_http.R.
# All functions here are pure: they return values and never touch globals.

# ---------------------------------------------------------------------------
# Low-level pieces

fetch_dj_page <- function(path) {
  url <- playlist_url(path)
  message("  ", url)
  safe_get_html(url)
}

empty_show_links <- function() {
  tibble::tibble(
    DJ = character(0),
    AirDate = as.Date(character(0)),
    show_id = character(0)
  )
}

# "X filled in" entries mean another DJ hosted the slot; that show belongs to
# the other DJ's playlists and is ignored here. "Fill-in for Y" entries are the
# DJ's own shows in someone else's slot and are kept.
fill_in_pattern <- stringr::regex("filled in", ignore_case = TRUE)

# Air dates of modern episodes, keyed by show_id ("shows/92163").
# Each modern entry starts with <span class="KDBepisode" id="KDBepisode-92163">
# followed directly by its date, e.g. "March 22, 2020 (This show was
# originally aired on 6/27/2010):". Reading the date there is independent of
# page layout: some pages (e.g. TW) put every entry in one flat <div>, and
# episode titles often contain other dates. Fill-in entries, e.g.
# "May 3, 2020 (Suzy Hotrod filled in.)", belong to the other DJ, whose page
# lists them, so they are flagged for removal.
episode_dates <- function(doc) {
  spans <- rvest::html_elements(doc, "span.KDBepisode")
  lead_text <- purrr::map_chr(spans, \(s) {
    xml2::xml_find_all(s, "following::text()[normalize-space()][position() <= 2]") |>
      xml2::xml_text() |>
      paste(collapse = " ")
  })
  tibble::tibble(
    show_id = paste0("shows/", stringr::str_extract(rvest::html_attr(spans, "id"), "\\d+$")),
    date_chr = stringr::str_extract(lead_text, date_pattern),
    fill_in = stringr::str_detect(lead_text, fill_in_pattern)
  ) |>
    dplyr::distinct(show_id, .keep_all = TRUE)
}

# Date of the entry an anchor sits in, for links without an episode span.
# Usually the parent element is the entry and holds one date. On flat pages
# (e.g. TW) the parent holds every entry, so use the nearest date before the
# anchor instead.
entry_date <- function(anchor, parent_text) {
  if (stringr::str_count(parent_text, date_pattern) <= 1) {
    return(stringr::str_extract(parent_text, date_pattern))
  }
  preceding <- xml2::xml_find_all(anchor, "preceding::text()[position() <= 25]") |>
    xml2::xml_text()
  hits <- preceding[stringr::str_detect(preceding, date_pattern)]
  if (length(hits) == 0) {
    return(NA_character_)
  }
  # fill-in notes sit right before their links
  if (stringr::str_detect(dplyr::last(hits), fill_in_pattern)) {
    return(NA_character_)
  }
  dplyr::last(stringr::str_extract_all(dplyr::last(hits), date_pattern)[[1]])
}

# Extract dated playlist links from a parsed DJ page.
# Returns DJ, AirDate, show_id (e.g. "shows/168921") plus, as an attribute,
# the ids of any prior-year pages found ("AQ2025", ...).
parse_show_links <- function(doc, dj_id) {
  anchors <- rvest::html_elements(
    doc,
    xpath = ".//a[contains(translate(@href,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'/playlist')]"
  )
  if (length(anchors) == 0) {
    return(structure(empty_show_links(), prior_years = character(0)))
  }

  hrefs <- rvest::html_attr(anchors, "href")

  show_ids <- normalize_show_id(hrefs)

  episodes <- episode_dates(doc)
  ep <- match(show_ids, episodes$show_id)
  date_chr <- dplyr::coalesce(
    episodes$date_chr[ep],
    stringr::str_extract(rvest::html_text2(anchors), date_pattern)
  )
  date_chr[episodes$fill_in[ep] %in% TRUE] <- NA

  # Remaining (mostly legacy) links: take the date from the enclosing entry.
  # Flat pages share one huge parent, so read each parent's text only once.
  todo <- which(is.na(date_chr) & !(episodes$fill_in[ep] %in% TRUE))
  if (length(todo) > 0) {
    parent_paths <- purrr::map_chr(anchors[todo], \(a) xml2::xml_path(xml2::xml_parent(a)))
    first_idx <- todo[match(unique(parent_paths), parent_paths)]
    parent_texts <- purrr::map_chr(
      first_idx, \(i) rvest::html_text2(xml2::xml_parent(anchors[[i]]))
    ) |>
      rlang::set_names(unique(parent_paths))
    date_chr[todo] <- purrr::map2_chr(
      as.list(anchors[todo]), unname(parent_texts[parent_paths]), entry_date
    )
  }

  prior_years <- hrefs |>
    normalize_show_id() |>
    stringr::str_subset(paste0("^", dj_id, "\\d{4}$")) |>
    unique()

  # Modern playlists look like /playlists/shows/168921, but very old shows
  # use legacy paths such as /Playlists/Bob/bb12.html; keep both.
  links <- tibble::tibble(DJ = dj_id, date_chr = date_chr, href = hrefs, show_id = show_ids) |>
    dplyr::filter(
      !is.na(date_chr),
      show_id != "",
      # self, prior-year, and other DJs' landing pages
      !is_dj_page(show_id),
      # absolute links to the modern site point at other DJs' pages
      !stringr::str_detect(href, "wfmu\\.org/playlists")
    ) |>
    dplyr::mutate(
      AirDate = as.Date(lubridate::parse_date_time(date_chr, orders = "BdY", quiet = TRUE))
    ) |>
    dplyr::select(DJ, AirDate, show_id) |>
    dplyr::distinct()

  structure(links, prior_years = prior_years)
}

# Profile URL and the DJ's other show names, from a parsed DJ page.
parse_dj_profile <- function(doc, dj_id) {
  profile_url <- doc |>
    rvest::html_elements(xpath = "//a[contains(@href,'profile')]") |>
    rvest::html_attr("href") |>
    purrr::pluck(1, .default = NA_character_)

  other_shownames <- "none"
  if (!is.na(profile_url)) {
    profile_doc <- safe_get_html(profile_url)
    if (!is.null(profile_doc)) {
      names <- profile_doc |>
        rvest::html_elements(".KDBprogram + a") |>
        rvest::html_text2()
      if (length(names) > 0) {
        other_shownames <- paste0(names, collapse = "\n")
      }
    }
  } else {
    profile_url <- playlist_url(dj_id)
  }

  tibble::tibble(
    DJ = dj_id,
    profileURL = profile_url,
    other_shownames = other_shownames
  )
}

# ---------------------------------------------------------------------------
# Public entry point

# Scrape a DJ. Returns list(links = <DJ, AirDate, show_id>, profile = <1 row>).
# With full_history = TRUE, prior-year pages are followed as well; otherwise
# only the current season page is read (fast, suitable for routine updates).
# With fetch_profile = FALSE the profile page request is skipped and
# profile = NULL (use when the profile is already cached).
scrape_dj <- function(dj_id, full_history = FALSE, fetch_profile = TRUE) {
  doc <- fetch_dj_page(dj_id)
  if (is.null(doc)) {
    return(list(links = empty_show_links(), profile = NULL))
  }

  links <- parse_show_links(doc, dj_id)
  profile <- if (fetch_profile) parse_dj_profile(doc, dj_id) else NULL

  if (full_history) {
    prior_links <- attr(links, "prior_years") |>
      purrr::map(\(yr) {
        yr_doc <- fetch_dj_page(yr)
        if (is.null(yr_doc)) empty_show_links() else parse_show_links(yr_doc, dj_id)
      }) |>
      purrr::list_rbind()
    links <- dplyr::bind_rows(links, prior_links)
  }

  list(
    links = dplyr::distinct(tibble::as_tibble(links)),
    profile = profile
  )
}
