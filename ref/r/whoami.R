# whoami.R - read a whoami report.
#
# SPDX-License-Identifier: MIT
#
# A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
# Every number in it is therefore input, not instruction -- including the counts
# that say how far to read. SPEC.md "Reading one safely" is the contract this
# file implements: the format tells a reader how far to read, and the reader
# decides how far it is willing to. Both halves are required. A length you
# trust without a bound is not a safety feature, it is an instruction.
#
# WHY R IS A REAL CONSUMER HERE. Bench data gets analyzed in R, and an analysis
# that silently attributes a run to the wrong board is worse than one that
# fails: the number still comes out, and it looks fine. Reading the identity
# report alongside the measurements is how a data frame keeps knowing which
# device produced it.
#
# NO REGULAR EXPRESSIONS ON UNTRUSTED INPUT, matching every other reference
# implementation. substr() and fixed-string comparisons only.
#
# NOT A VALIDATOR. It answers "what does this say", bounded and without
# trusting it. Conformance is a separate, stricter question.

GRID <- 11L           # columns 1-11 are the label; the value starts at 12

# Bounds. Each exists so a hostile or broken far end cannot make a reader work
# harder than the reader chose to.
MAX_LINES    <- 500L  # total, so a looping device is a failed read
MAX_SPECIAL  <- 100L  # lines skipped for one block
MAX_SPEAKS   <- 16L   # majors recorded from the speaks line
MAX_FIELDS   <- 64L   # fields recorded; the rest are counted only
PREAMBLE_MAX <- 512L  # bytes before the preamble must have landed

# Errors carry a condition class, so a caller classifies on the class and never
# on the message: a message is for a human and may be reworded.
whoami_stop <- function(token, message) {
  structure(
    class = c(paste0("whoami_", token), "whoami_error", "error", "condition"),
    list(message = message, call = NULL, token = token)
  )
}

whoami_raise <- function(token, message) stop(whoami_stop(token, message))

# Non-negative decimal, or NA.
#
# Length-capped BEFORE conversion, because a count that wrapped is a count the
# far end chose, and obeying it is the failure this refuses. as.integer() is
# not used on its own: it accepts " 12 ", "1e3", "0x10" and "-1", every one of
# which is a number the far end would like this reader to believe.
whoami_to_int <- function(s) {
  if (is.na(s) || nchar(s) == 0L || nchar(s) > 9L) return(NA_integer_)
  chars <- strsplit(s, "", fixed = TRUE)[[1L]]
  if (any(chars < "0" | chars > "9")) return(NA_integer_)
  as.integer(s)
}

# Label and value, BY SLICE AND NOT BY SPLITTING ON WHITESPACE.
#
# Columns 1..GRID are the label, right-trimmed; the rest is the value,
# left-trimmed. That fixed width is the whole reason the grid exists: it lets a
# label contain a space -- `front end` -- with no escaping and no ambiguity
# about where it ends. Splitting on the first space instead reads that label as
# `front` and silently moves `end` into the value: a corrupted read that looks
# like a successful one.
whoami_split <- function(line) {
  if (nchar(trimws(line)) == 0L) return(list(label = NA_character_, value = ""))
  label <- sub("[ \t]+$", "", substr(line, 1L, GRID))
  if (nchar(label) == 0L) return(list(label = NA_character_, value = ""))
  value <- if (nchar(line) > GRID) {
    sub("^[ \t]+", "", substr(line, GRID + 1L, nchar(line)))
  } else {
    ""
  }
  list(label = label, value = value)
}

whoami_parse_schema <- function(value) {
  dot <- regexpr(".", value, fixed = TRUE)[[1L]]
  if (dot < 2L || dot >= nchar(value)) {
    whoami_raise("schema", "schema value not <major>.<4 digits>")
  }
  major_text <- substr(value, 1L, dot - 1L)
  rev_text <- substr(value, dot + 1L, nchar(value))
  # FOUR DIGITS, zero-padded, always. Fixed width is what makes 1.0012 and
  # 1.0002 compare correctly as text, and a reader that accepts 1.12 is
  # accepting a report no conformant emitter produces.
  if (nchar(rev_text) != 4L) {
    whoami_raise("schema", "schema value not <major>.<4 digits>")
  }
  major <- whoami_to_int(major_text)
  revision <- whoami_to_int(rev_text)
  if (is.na(major) || is.na(revision)) {
    whoami_raise("schema", "schema value not <major>.<4 digits>")
  }
  list(major = major, revision = revision)
}

whoami_parse_speaks <- function(value) {
  words <- strsplit(trimws(value), "[ \t]+")[[1L]]
  majors <- integer(0)
  truncated <- FALSE
  for (word in words) {
    if (nchar(word) == 0L) next
    major <- whoami_to_int(word)
    if (is.na(major)) next  # unreadable entry; the rest may be fine
    if (length(majors) < MAX_SPEAKS) majors <- c(majors, major) else truncated <- TRUE
  }
  list(speaks = majors, truncated = truncated)
}

#' Parse a whoami report.
#'
#' @param text A length-one character vector, or a raw vector of bytes.
#' @return A list with major, revision, speaks, fields (a named list),
#'   labels (order preserved, so a duplicate or an overlong label is still
#'   visible), special_blocks, lines_read, and refusal.
whoami_parse <- function(text) {
  if (is.raw(text)) {
    # Latin-1 never fails and never reinterprets a byte, so a report carrying
    # something unexpected is READ rather than refused.
    text <- rawToChar(text)
    Encoding(text) <- "latin1"
  }
  if (length(text) != 1L || is.na(text) || nchar(text) == 0L) {
    whoami_raise("empty", "empty report")
  }

  # BOUND THE PREAMBLE READ. A device that never sends a newline must not be
  # able to hang a reader, and the preamble's whole value is that the decision
  # is cheap -- so cap the bytes before it has to have landed.
  if (nchar(text) > PREAMBLE_MAX) {
    head_text <- substr(text, 1L, PREAMBLE_MAX)
    newlines <- sum(strsplit(head_text, "", fixed = TRUE)[[1L]] == "\n")
    if (newlines < 2L) {
      whoami_raise("bounds", sprintf(
        "report exceeded its bound (no newline within the first %d bytes)",
        PREAMBLE_MAX))
    }
  }

  lines <- strsplit(text, "\n", fixed = TRUE)[[1L]]
  lines <- sub("\r$", "", lines)
  if (length(lines) < 2L) whoami_raise("preamble", "missing or malformed preamble")

  first <- whoami_split(lines[[1L]])
  if (is.na(first$label) || first$label != "schema") {
    whoami_raise("preamble", "missing or malformed preamble")
  }
  schema <- whoami_parse_schema(first$value)

  second <- whoami_split(lines[[2L]])
  if (is.na(second$label) || second$label != "speaks") {
    whoami_raise("preamble", "missing or malformed preamble")
  }
  spoken <- whoami_parse_speaks(second$value)

  report <- list(
    major = schema$major, revision = schema$revision,
    schema = sprintf("%d.%04d", schema$major, schema$revision),
    speaks = spoken$speaks, speaks_truncated = spoken$truncated,
    fields = list(), labels = character(0), fields_seen = 0L,
    special_blocks = 0L, lines_read = 2L, refusal = FALSE
  )

  rest <- if (length(lines) > 2L) lines[3:length(lines)] else character(0)
  # Preamble and nothing else is a REFUSAL, and a successful read: the device
  # answered with the frozen preamble alone, which is what one that cannot
  # speak the requested major is required to do.
  if (length(rest) == 0L || all(nchar(trimws(rest)) == 0L)) {
    report$refusal <- TRUE
    return(report)
  }

  index <- 1L
  while (index <= length(rest)) {
    line <- rest[[index]]
    index <- index + 1L
    report$lines_read <- report$lines_read + 1L
    if (report$lines_read > MAX_LINES) {
      whoami_raise("bounds", "report exceeded its line bound")
    }
    if (nchar(trimws(line)) == 0L) next

    parsed <- whoami_split(line)
    if (is.na(parsed$label)) next

    if (parsed$label == "special") {
      # `special <count> <tag>` -- the count only. The tag is deliberately not
      # interpreted: not knowing it is the expected case, not an error.
      first_word <- strsplit(trimws(parsed$value), "[ \t]+")[[1L]][[1L]]
      count <- whoami_to_int(first_word)
      # BOUND THE COUNT. An unbounded count supplied by the far end is a
      # request to read forever. Past the cap it is a malformed report, not an
      # instruction to obey.
      if (is.na(count) || count > MAX_SPECIAL) {
        whoami_raise("special", "special block count past the bound")
      }
      if (count > 0L) {
        skip <- min(count, length(rest) - index + 1L)  # truncated: skip what exists
        index <- index + skip
        report$lines_read <- report$lines_read + skip
        if (report$lines_read > MAX_LINES) {
          whoami_raise("bounds", "report exceeded its line bound")
        }
      }
      report$special_blocks <- report$special_blocks + 1L
      next
    }

    report$fields_seen <- report$fields_seen + 1L
    # Past the cap a field is counted but not stored, so fields_seen !=
    # length(labels) tells a caller it did not see everything. First match
    # wins; a duplicate label is a conformance question, not a reading one.
    if (length(report$labels) < MAX_FIELDS && !(parsed$label %in% report$labels)) {
      report$fields[[parsed$label]] <- parsed$value
      report$labels <- c(report$labels, parsed$label)
    }
  }
  report
}

#' Field lookup. Returns NULL when absent, never "" -- an absent field and a
#' field whose value is empty are different facts.
whoami_get <- function(report, label) {
  if (label %in% report$labels) report$fields[[label]] else NULL
}

whoami_speaks <- function(report, major) major %in% report$speaks
