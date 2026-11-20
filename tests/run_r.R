# Run the shared corpus against ref/r/whoami.R.
#
# SPDX-License-Identifier: MIT
#
# Same job and same output shape as every other runner here, so results can be
# compared line for line. The corpus is the authority; a runner that disagrees
# with it is reporting a defect in its implementation.
#
# Classification is BY CONDITION CLASS, never by message text: a message is for
# a human and may be reworded, while the class is the contract.

args <- commandArgs(trailingOnly = TRUE)
here <- dirname(normalizePath(sub("^--file=", "",
  grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1L])))
repo <- dirname(here)
corpus <- if (length(args) > 0L) args[[1L]] else file.path(here, "corpus")

source(file.path(repo, "ref", "r", "whoami.R"))

load_expect <- function(path) {
  out <- list()
  lines <- readLines(path, warn = FALSE)
  for (raw in lines) {
    if (nchar(raw) == 0L || substr(raw, 1L, 1L) == "#") next
    eq <- regexpr("=", raw, fixed = TRUE)[[1L]]  # FIRST equals
    if (eq < 1L) next
    key <- substr(raw, 1L, eq - 1L)
    value <- substr(raw, eq + 1L, nchar(raw))
    out[[key]] <- value
  }
  out
}

check <- function(name) {
  problems <- character(0)
  # readBin, not readLines: readLines normalizes line endings and drops a
  # missing final newline, repairing the very malformations under test.
  size <- file.info(file.path(corpus, paste0(name, ".report")))$size
  bytes <- readBin(file.path(corpus, paste0(name, ".report")), "raw", n = size)
  expect <- load_expect(file.path(corpus, paste0(name, ".expect")))
  want_error <- identical(expect[["status"]], "error")

  report <- NULL
  tryCatch({
    report <- whoami_parse(bytes)
    if (want_error) {
      problems <<- c(problems, "read succeeded, but this case exists to be refused")
    }
  }, whoami_error = function(e) {
    got <- e$token
    if (!want_error) {
      problems <<- c(problems, sprintf(
        "raised '%s' but the case expects a successful read", got))
    } else if (!is.null(expect[["error"]]) && !identical(got, expect[["error"]])) {
      problems <<- c(problems, sprintf("error token '%s', corpus says '%s'",
                                       got, expect[["error"]]))
    }
  })

  if (is.null(report)) return(problems)

  for (key in sort(names(expect))) {
    want <- expect[[key]]
    if (key %in% c("status", "error")) next
    if (startsWith(key, "field.")) {
      label <- substr(key, 7L, nchar(key))
      got <- whoami_get(report, label)
      if (is.null(got)) {
        problems <- c(problems, sprintf("field '%s' absent, corpus says '%s'",
                                        label, want))
      } else if (!identical(got, want)) {
        problems <- c(problems, sprintf("field '%s' is '%s', corpus says '%s'",
                                        label, got, want))
      }
      next
    }
    got <- switch(key,
      major = as.character(report$major),
      revision = as.character(report$revision),
      refusal = if (report$refusal) "true" else "false",
      blocks = as.character(report$special_blocks),
      speaks = paste(report$speaks, collapse = " "),
      NULL)
    if (is.null(got)) next
    if (!identical(got, want)) {
      problems <- c(problems, sprintf("%s is '%s', corpus says '%s'", key, got, want))
    }
  }
  problems
}

names_ <- trimws(readLines(file.path(corpus, "INDEX"), warn = FALSE))
names_ <- names_[nchar(names_) > 0L]
bad <- 0L
for (name in names_) {
  problems <- check(name)
  if (length(problems) > 0L) bad <- bad + 1L
  cat(sprintf("  %-4s %s\n", if (length(problems) > 0L) "FAIL" else "ok", name))
  for (p in problems) cat(sprintf("        %s\n", p))
}
cat("\n")
cat(sprintf("  r: %d cases, %d failed\n", length(names_), bad))
quit(status = if (bad > 0L) 1L else 0L)
