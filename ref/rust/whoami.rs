//! Read a whoami report.
//!
//! SPDX-License-Identifier: MIT
//!
//! A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
//! Every number in it is therefore input, not instruction -- including the
//! counts that say how far to read. SPEC.md "Reading one safely" is the
//! contract this file implements: the format tells a reader how far to read,
//! and the reader decides how far it is willing to. Both halves are required.
//! A length you trust without a bound is not a safety feature, it is an
//! instruction.
//!
//! NO ALLOCATION AND NO `std`. Fixed-size arrays and borrowed `&str`, so this
//! builds for a microcontroller unchanged -- which matters, because the thing
//! most likely to be reading another board's identity on a bus IS another
//! board. The report borrows the caller's buffer; nothing is copied.
//!
//! RUST'S SAFETY DOES NOT COVER THE INTERESTING PART. The borrow checker will
//! not stop this reader from obeying a `special` count of four billion, and a
//! `usize` from the far end is as dangerous here as an `int` is in C. The
//! bounds below are the actual safety property; the type system just makes
//! them cheaper to hold onto.
//!
//! NOT A VALIDATOR. It answers "what does this say", bounded and without
//! trusting it. Conformance is a separate, stricter question.

// NO `#![no_std]` HERE, DELIBERATELY. `no_std` is a crate-level attribute, and
// this file is meant to be usable BOTH as its own crate and as a module pulled
// in with `#[path]`. Declaring it here makes the second form fail to compile,
// which would mean the reference implementation could not be checked by the
// reference runner.
//
// It uses nothing but `core` regardless, so a `no_std` crate takes it as-is:
// put `#![no_std]` at your own crate root and this compiles unchanged.

/// Columns 1..GRID hold the label; the value starts after it.
pub const GRID: usize = 11;

// Bounds. Each exists so a hostile or broken far end cannot make a reader work
// harder than the reader chose to.
pub const MAX_LINES: usize = 500;
pub const MAX_SPECIAL: usize = 100;
pub const MAX_SPEAKS: usize = 16;
pub const MAX_FIELDS: usize = 64;
pub const PREAMBLE_MAX: usize = 512;

/// The canonical failure tokens. Callers classify on these, never on a
/// message: a message is for a human and may be reworded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Empty,
    Preamble,
    Schema,
    Special,
    Bounds,
}

impl Error {
    pub fn token(self) -> &'static str {
        match self {
            Error::Empty => "empty",
            Error::Preamble => "preamble",
            Error::Schema => "schema",
            Error::Special => "special",
            Error::Bounds => "bounds",
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Field<'a> {
    pub label: &'a str,
    pub value: &'a str,
}

#[derive(Debug, Clone)]
pub struct Report<'a> {
    pub major: u32,
    pub revision: u32,
    speaks: [u32; MAX_SPEAKS],
    speaks_len: usize,
    pub speaks_truncated: bool,
    fields: [Field<'a>; MAX_FIELDS],
    fields_len: usize,
    /// Including any past `MAX_FIELDS`, so `fields_seen != fields().len()`
    /// tells a caller it did not see everything -- rather than the report
    /// looking complete.
    pub fields_seen: usize,
    pub special_blocks: usize,
    pub lines_read: usize,
    /// A REFUSAL IS A SUCCESSFUL READ, not an error: the device answered with
    /// the frozen preamble alone, which is what one that cannot speak the
    /// requested major is required to do, and is the one answer a reader of
    /// ANY major is guaranteed to understand.
    pub refusal: bool,
}

impl<'a> Default for Report<'a> {
    fn default() -> Self {
        Report {
            major: 0,
            revision: 0,
            speaks: [0; MAX_SPEAKS],
            speaks_len: 0,
            speaks_truncated: false,
            fields: [Field { label: "", value: "" }; MAX_FIELDS],
            fields_len: 0,
            fields_seen: 0,
            special_blocks: 0,
            lines_read: 0,
            refusal: false,
        }
    }
}

impl<'a> Report<'a> {
    pub fn fields(&self) -> &[Field<'a>] {
        &self.fields[..self.fields_len]
    }

    pub fn speaks(&self) -> &[u32] {
        &self.speaks[..self.speaks_len]
    }

    /// First match wins. A duplicate label is a conformance question, not a
    /// reading one.
    pub fn get(&self, label: &str) -> Option<&'a str> {
        self.fields().iter().find(|f| f.label == label).map(|f| f.value)
    }

    pub fn speaks_major(&self, major: u32) -> bool {
        self.speaks().contains(&major)
    }
}

/// Non-negative decimal, or `None`.
///
/// Length-capped BEFORE conversion, because a count that wrapped is a count
/// the far end chose, and obeying it is the failure this refuses. `str::parse`
/// is not used on its own: it accepts a leading `+`, and the point here is to
/// accept exactly one shape.
fn to_u32(s: &str) -> Option<u32> {
    if s.is_empty() || s.len() > 9 {
        return None;
    }
    let mut value: u32 = 0;
    for byte in s.as_bytes() {
        if !byte.is_ascii_digit() {
            return None;
        }
        value = value * 10 + u32::from(byte - b'0');
    }
    Some(value)
}

/// Label and value, BY SLICE AND NOT BY SPLITTING ON WHITESPACE.
///
/// Columns 1..GRID are the label, right-trimmed; the rest is the value,
/// left-trimmed. That fixed width is the whole reason the grid exists: it lets
/// a label contain a space -- `front end` -- with no escaping and no ambiguity
/// about where it ends. Splitting on the first space instead reads that label
/// as `front` and silently moves `end` into the value: a corrupted read that
/// looks like a successful one.
pub fn split_line(line: &str) -> Option<Field<'_>> {
    if line.trim().is_empty() {
        return None;
    }
    // Byte indexing is safe here only because a conformant report is ASCII in
    // its label field; `get` returns None rather than panicking if a multibyte
    // character straddles the boundary, which is the right answer for a line
    // no conformant emitter produced.
    let cut = core::cmp::min(GRID, line.len());
    let label = line.get(..cut)?.trim_end();
    if label.is_empty() {
        return None;
    }
    let value = if line.len() > GRID {
        line.get(GRID..).unwrap_or("").trim_start()
    } else {
        ""
    };
    Some(Field { label, value })
}

fn parse_schema(value: &str, report: &mut Report<'_>) -> Result<(), Error> {
    let dot = value.find('.').ok_or(Error::Schema)?;
    if dot == 0 || dot + 1 >= value.len() {
        return Err(Error::Schema);
    }
    let revision = &value[dot + 1..];
    // FOUR DIGITS, zero-padded, always. Fixed width is what makes 1.0012 and
    // 1.0002 compare correctly as text, and a reader that accepts 1.12 is
    // accepting a report no conformant emitter produces.
    if revision.len() != 4 {
        return Err(Error::Schema);
    }
    report.major = to_u32(&value[..dot]).ok_or(Error::Schema)?;
    report.revision = to_u32(revision).ok_or(Error::Schema)?;
    Ok(())
}

fn parse_speaks(value: &str, report: &mut Report<'_>) {
    for word in value.split_whitespace() {
        let Some(major) = to_u32(word) else {
            continue; // unreadable entry; the rest may be fine
        };
        if report.speaks_len < MAX_SPEAKS {
            report.speaks[report.speaks_len] = major;
            report.speaks_len += 1;
        } else {
            report.speaks_truncated = true;
        }
    }
}

/// Parse a report. Lines may end LF or CRLF; the buffer is not modified.
pub fn parse(text: &str) -> Result<Report<'_>, Error> {
    let mut report = Report::default();
    if text.is_empty() {
        return Err(Error::Empty);
    }

    // BOUND THE PREAMBLE READ. A device that never sends a newline must not be
    // able to hang a reader, and the preamble's whole value is that the
    // decision is cheap -- so cap the bytes before it has to have landed.
    if text.len() > PREAMBLE_MAX {
        let head = &text.as_bytes()[..PREAMBLE_MAX];
        if head.iter().filter(|b| **b == b'\n').count() < 2 {
            return Err(Error::Bounds);
        }
    }

    let mut lines = text.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l));

    let first = split_line(lines.next().ok_or(Error::Preamble)?).ok_or(Error::Preamble)?;
    if first.label != "schema" {
        return Err(Error::Preamble);
    }
    report.lines_read += 1;
    parse_schema(first.value, &mut report)?;

    let second = split_line(lines.next().ok_or(Error::Preamble)?).ok_or(Error::Preamble)?;
    if second.label != "speaks" {
        return Err(Error::Preamble);
    }
    report.lines_read += 1;
    parse_speaks(second.value, &mut report);

    // Collect the remainder once so "is the rest blank" and the body walk see
    // the same lines; a second pass over the iterator would consume it.
    let mut rest: [&str; MAX_LINES] = [""; MAX_LINES];
    let mut rest_len = 0usize;
    for line in lines {
        if rest_len >= MAX_LINES {
            return Err(Error::Bounds);
        }
        rest[rest_len] = line;
        rest_len += 1;
    }

    // Preamble and nothing else is a refusal, and a successful read.
    if rest[..rest_len].iter().all(|l| l.trim().is_empty()) {
        report.refusal = true;
        return Ok(report);
    }

    let mut index = 0usize;
    while index < rest_len {
        let line = rest[index];
        index += 1;
        report.lines_read += 1;
        if report.lines_read > MAX_LINES {
            return Err(Error::Bounds);
        }
        if line.trim().is_empty() {
            continue;
        }
        let Some(field) = split_line(line) else {
            continue;
        };

        if field.label == "special" {
            // `special <count> <tag>` -- the count only. The tag is
            // deliberately not interpreted: not knowing it is the expected
            // case, not an error.
            let first_word = field.value.split_whitespace().next().unwrap_or("");
            // BOUND THE COUNT. An unbounded count supplied by the far end is a
            // request to read forever. Past the cap it is a malformed report,
            // not an instruction to obey.
            let count = match to_u32(first_word) {
                Some(n) if (n as usize) <= MAX_SPECIAL => n as usize,
                _ => return Err(Error::Special),
            };
            for _ in 0..count {
                if index >= rest_len {
                    break; // truncated; nothing left to skip
                }
                index += 1;
                report.lines_read += 1;
                if report.lines_read > MAX_LINES {
                    return Err(Error::Bounds);
                }
            }
            report.special_blocks += 1;
            continue;
        }

        report.fields_seen += 1;
        if report.fields_len < MAX_FIELDS {
            report.fields[report.fields_len] = field;
            report.fields_len += 1;
        }
    }
    Ok(report)
}
