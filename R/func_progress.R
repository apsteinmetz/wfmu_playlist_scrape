# Progress messages for long-running steps.
#
#   progress_start()          reset the elapsed-time clock
#   progress("Reading ...")   "[18:20:31 |   2.4 min] Reading ..."
#
# Messages go to stderr via message(), so they show in the terminal and the
# console. If progress_start() was never called, the clock starts at the
# first progress() call.

.progress_clock <- new.env()

progress_start <- function() {
  .progress_clock$start <- Sys.time()
  invisible()
}

progress <- function(...) {
  now <- Sys.time()
  if (is.null(.progress_clock$start)) .progress_clock$start <- now
  elapsed <- as.numeric(difftime(now, .progress_clock$start, units = "mins"))
  message(sprintf("[%s | %5.1f min] %s", format(now, "%H:%M:%S"), elapsed, paste0(...)))
  invisible()
}

# 1234567 -> "1,234,567"
fmt_n <- function(x) format(x, big.mark = ",", scientific = FALSE, trim = TRUE)
