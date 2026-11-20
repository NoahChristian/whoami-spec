"""Read a whoami report. Python and MicroPython, same file.

SPDX-License-Identifier: MIT

A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
Every number in it is therefore input, not instruction -- including the counts
that say how far to read. SPEC.md "Reading one safely" is the contract this
module implements, and the shape of all of it is: the format tells a reader how
far to read, and the reader decides how far it is willing to. Both halves are
required. A length you trust without a bound is not a safety feature, it is an
instruction.

WRITTEN TO THE MICROPYTHON SUBSET, ON PURPOSE. A board running MicroPython is
exactly the kind of thing that needs to identify its neighbor on a bus, so this
has to run there and not only on a workstation:

  * No `re`. MicroPython's is a reduced engine, and a parser whose safety rests
    on a regex is one backtracking pattern away from the denial of service the
    bounds exist to prevent. String operations only -- which is also what makes
    this file behave identically to the C implementation beside it.
  * No `dataclasses`, no `enum`, no `typing`, no f-strings.
  * No recursion, no allocation proportional to anything the far end chose.

NOT A VALIDATOR. It answers "what does this say", bounded and without trusting
it. Whether a report is CONFORMANT is a separate and stricter question, and
tools/whoami_check.py answers that -- by calling this. Keeping them apart
matters because a reader in the field must cope with a report it would also
have reported as non-conformant.
"""

GRID = 11               # columns 1-11 are the label; the value starts at 12

# Bounds. Each exists so a hostile or broken far end cannot make a reader work
# harder than the reader chose to.
MAX_LINES = 500         # total, so a looping device is a failed read
MAX_SPECIAL = 100       # lines skipped for one block
MAX_SPEAKS = 16         # majors recorded from the speaks line
MAX_FIELDS = 64         # fields recorded; the rest are counted only
PREAMBLE_MAX = 512      # bytes before the preamble must have landed

OK = "ok"
E_EMPTY = "empty"
E_PREAMBLE = "missing or malformed preamble"
E_SCHEMA = "schema value not <major>.<4 digits>"
E_TOO_LONG = "report exceeded its bound"
E_SPECIAL = "special block count past the bound"


class WhoamiError(Exception):
    """A report that could not be read within the bounds this reader set."""

    def __init__(self, status, report=None):
        Exception.__init__(self, status)
        self.status = status
        # Filled in as far as parsing got, so a caller can say what it DID
        # understand -- which for an unidentified device is usually more useful
        # than the error alone.
        self.report = report


class Report(object):
    """What a report says. Values are text; interpretation is the caller's."""

    def __init__(self):
        self.major = 0
        self.revision = 0
        self.speaks = []
        self.speaks_truncated = False
        self.fields = []        # list of (label, value), in order
        self.fields_seen = 0    # including any past MAX_FIELDS
        self.special_blocks = 0
        self.lines_read = 0
        # A REFUSAL IS A SUCCESSFUL READ, not an error. The device answered
        # with the preamble alone, which is what SPEC.md requires of one that
        # cannot speak the requested major -- and is the one answer a reader of
        # ANY major is guaranteed to understand.
        self.refusal = False

    def get(self, label, default=None):
        """First match wins. A duplicate label is a conformance question."""
        for name, value in self.fields:
            if name == label:
                return value
        return default

    def has(self, label):
        return self.get(label) is not None

    def speaks_major(self, major):
        return major in self.speaks

    @property
    def schema(self):
        return "%d.%04d" % (self.major, self.revision)

    def __repr__(self):
        return "<Report schema=%s speaks=%s fields=%d%s>" % (
            self.schema, self.speaks, len(self.fields),
            " REFUSAL" if self.refusal else "")


def _is_digits(s):
    if not s:
        return False
    for ch in s:
        if ch < "0" or ch > "9":
            return False
    return True


def _to_int(s):
    """Non-negative decimal, or None. Length-capped before conversion, because
    a count that wrapped is a count the far end chose and obeying it is the
    failure this refuses."""
    if not _is_digits(s) or len(s) > 9:
        return None
    return int(s)


def _split(line):
    """Label and value, BY SLICE AND NOT BY SEARCHING FOR WHITESPACE.

    Columns 1-11 are the label, right-trimmed; column 12 onward is the value,
    left-trimmed. This is the whole reason the grid is fixed-width: it lets a
    label contain a space -- `front end` -- with no escaping and no ambiguity
    about where it ends. Splitting on the first space instead reads that label
    as `front` and silently moves `end` into the value, which is a corrupted
    read that looks like a successful one.
    """
    if not line.strip():
        return None, None
    label = line[:GRID].rstrip()
    value = line[GRID:].lstrip()
    if not label:
        return None, None
    return label, value


def _parse_schema(value, report):
    dot = value.find(".")
    if dot <= 0 or dot >= len(value) - 1:
        raise WhoamiError(E_SCHEMA, report)
    # FOUR DIGITS, zero-padded, always. Fixed width is what makes "1.0012" and
    # "1.0002" compare correctly as text, and a reader that accepts "1.12" is
    # accepting a report no conformant emitter produces.
    major, revision = value[:dot], value[dot + 1:]
    if len(revision) != 4:
        raise WhoamiError(E_SCHEMA, report)
    m, r = _to_int(major), _to_int(revision)
    if m is None or r is None:
        raise WhoamiError(E_SCHEMA, report)
    report.major, report.revision = m, r


def _parse_speaks(value, report):
    for word in value.split():
        major = _to_int(word)
        if major is None:
            continue        # unreadable entry; the rest may be fine
        if len(report.speaks) < MAX_SPEAKS:
            report.speaks.append(major)
        else:
            report.speaks_truncated = True


def parse(text):
    """Parse a report. Returns a Report, or raises WhoamiError.

    Accepts str or bytes; lines may end LF or CRLF.
    """
    report = Report()
    if isinstance(text, (bytes, bytearray)):
        # Latin-1 never fails and never reinterprets a byte, so a report
        # carrying something unexpected is READ rather than refused. A decode
        # error here would turn a field problem into a total read failure.
        text = bytes(text).decode("latin-1")
    if not text:
        raise WhoamiError(E_EMPTY, report)

    # BOUND THE PREAMBLE READ. A device that never sends a newline must not be
    # able to hang a reader, and the preamble's whole value is that the
    # decision is cheap -- so cap the bytes before it has to have landed.
    if len(text) > PREAMBLE_MAX:
        head = text[:PREAMBLE_MAX]
        if head.count("\n") < 2:
            raise WhoamiError(E_TOO_LONG, report)

    lines = text.split("\n")
    index = 0

    def take():
        nonlocal index
        if index >= len(lines):
            return None
        line = lines[index]
        index += 1
        if line.endswith("\r"):
            line = line[:-1]
        return line

    first = take()
    if first is None:
        raise WhoamiError(E_EMPTY, report)
    label, value = _split(first)
    if label != "schema":
        raise WhoamiError(E_PREAMBLE, report)
    report.lines_read += 1
    _parse_schema(value, report)

    second = take()
    if second is None:
        raise WhoamiError(E_PREAMBLE, report)
    label, value = _split(second)
    if label != "speaks":
        raise WhoamiError(E_PREAMBLE, report)
    report.lines_read += 1
    _parse_speaks(value, report)

    # Preamble and nothing else is a refusal, and a successful read.
    rest = [ln for ln in lines[index:] if ln.strip()]
    if not rest:
        report.refusal = True
        return report

    while True:
        line = take()
        if line is None:
            break
        report.lines_read += 1
        if report.lines_read > MAX_LINES:
            raise WhoamiError(E_TOO_LONG, report)
        if not line.strip():
            continue
        label, value = _split(line)
        if label is None:
            continue

        if label == "special":
            # `special <count> <tag>` -- take the count only. The tag is
            # deliberately not interpreted: not knowing it is the expected
            # case, not an error.
            parts = value.split(None, 1)
            count = _to_int(parts[0]) if parts else None
            # BOUND THE COUNT. Anything past the cap is a malformed report
            # rather than an instruction to obey. An unbounded count from the
            # far end is a request to read forever -- the same guard the RS485
            # link on this bench keeps as LINK_MAX_LEN, where a length past a
            # sane bound is not a long frame, it is noise that happened to
            # contain a sync pattern.
            if count is None or count > MAX_SPECIAL:
                raise WhoamiError(E_SPECIAL, report)
            for _ in range(count):
                if take() is None:
                    break       # truncated; nothing left to skip
                report.lines_read += 1
                if report.lines_read > MAX_LINES:
                    raise WhoamiError(E_TOO_LONG, report)
            report.special_blocks += 1
            continue

        report.fields_seen += 1
        if len(report.fields) < MAX_FIELDS:
            report.fields.append((label, value))
        # Past the cap a field is counted but not stored, so fields_seen !=
        # len(fields) tells a caller it did not see everything -- rather than
        # the report looking complete.

    return report


def emit(info, requested_major=1, schema="1.0005", speaks=None):
    """Produce a report. The mirror of parse(), and the same grammar.

    `info` is a mapping with the required keys; see SPEC.md. Returns a list of
    lines. An empty body (preamble only) is the conformant REFUSAL for a major
    this device does not speak -- answering in the wrong major is the
    violation, not a lenient kindness.
    """
    majors = list(speaks) if speaks else [int(schema.split(".")[0])]
    out = ["%-11s%s" % ("schema", schema),
           "%-11s%s" % ("speaks", " ".join(str(m) for m in majors))]
    if requested_major not in majors:
        return out

    token, fw = info["token"], info["fw"]
    unit = info.get("unit")
    # `fw <version>` LAST, so a parser can take the final whitespace-separated
    # field without knowing whether `unit` was present.
    if unit is None:
        appid = "%s fw %s" % (token, fw)
    else:
        appid = "%s unit %d fw %s" % (token, int(unit), fw)
    out.append("%-11s%s" % ("appid", appid))
    for key in ("project", "board", "built", "uptime", "attest"):
        out.append("%-11s%s" % (key, info.get(key, "")))
    return out


def special(tag, lines):
    """A counted block of opaque lines. Returns [] rather than a half-written
    block if it would be malformed -- the header is a promise about how many
    lines follow, and a reader will skip exactly that many."""
    body = list(lines)
    if not tag or "." not in tag or len(body) > MAX_SPECIAL:
        return []
    for line in body:
        if not isinstance(line, str):
            return []
    return ["%-11s%d %s" % ("special", len(body), tag)] + body
