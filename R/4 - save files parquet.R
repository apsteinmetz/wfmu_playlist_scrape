# 4 - Copy outputs to the Shiny app
#
# Copies the files the app (../wfmu_explorer) reads into its data/ folder.
# file.copy() gives the copies a new modification time, which the app uses
# to invalidate its caches, so new data shows up on the next app start.

APP_DATA <- "../wfmu_explorer/data"

# source file in data/  =  name the app reads
app_files <- c(
  "playlists.parquet" = "playlists.parquet",
  "djsimilarity.parquet" = "djsimilarity.parquet",
  "distinctive_artists.parquet" = "distinctive_artists.parquet",
  "similarity_histogram_gg.rdata" = "similarity_histogram_gg.rdata",
  # the app reads the DJ key as djKey.parquet
  "dj_key.parquet" = "djKey.parquet",
  # not produced by any current script; copied as is (see agents/scrape_wfmu.md)
  "djdtm.rdata" = "djdtm.rdata"
)

sources <- file.path("data", names(app_files))
missing <- sources[!file.exists(sources)]
if (length(missing) > 0) stop("Missing source files: ", paste(missing, collapse = ", "))
if (!dir.exists(APP_DATA)) stop("App data folder not found: ", APP_DATA)

copied <- file.copy(sources, file.path(APP_DATA, app_files), overwrite = TRUE)
if (!all(copied)) stop("Copy failed for: ", paste(sources[!copied], collapse = ", "))

message("Copied ", length(copied), " files to ", APP_DATA)
