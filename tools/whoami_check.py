#!/usr/bin/env python3
"""Conformance checker for the whoami report format. See ../SPEC.md.

    whoami_check.py report <file> [<file> ...]   validate captured reports
    whoami_check.py tokens                       registry sanity
    whoami_check.py spec                         the revision gate
    whoami_check.py --selftest                   prove it still fires

THREE JOBS, AND THE THIRD IS THE ONE THAT KEEPS THE OTHER TWO TRUE.

`report` checks a captured report against the schema. `tokens` checks the
registry for the failure it exists to prevent -- two applications claiming one
name, which detection resolves by picking whichever answered first and is
wrong everywhere downstream.

`spec` enforces that editing SPEC.md bumps the revision. Nothing parses
differently because of that number, so without a gate it stops being
maintained: this bench watched a one-line commit rule go unobserved for 107
commits for exactly that reason, and a spelling rule hold only once it had a
check. A version field nobody enforces decays into a lie, which is worse than
no field, because people believe it.

WHAT THIS CANNOT DO, said here rather than discovered later. It reads TEXT. It
cannot tell you that a device's emitter and its documentation agree, only that
a captured report conforms -- so a board whose source was never run past this
is unverified however green the output looks. Capture a real report from real
hardware and feed it in; that is the only check that is about the device.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# The label column. SPEC.md: "a label, left-aligned in an 11-character field,
# then the value".
LABEL_WIDTH = 11

# Bounds, because SPEC.md's own "Reading one safely" section says a reader
# decides how far it is willing to go and does not take the far end's word.
# These are the checker BEING a conformant reader, not extra strictness.
MAX_LINES = 500
MAX_SPECIAL = 100

REQUIRED = ("schema", "speaks", "appid", "project", "board", "built",
            "uptime", "attest")

KNOWN_ATTEST = ("none", "ecdsa-p256")

SCHEMA_RE = re.compile(r"^(\d+)\.(\d{4})$")
SPEAKS_RE = re.compile(r"^\d+(?: \d+)*$")
TOKEN_RE = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
TAG_RE = re.compile(r"^[a-z][a-z0-9]*(?:\.[a-z0-9]+)+$")
# Labels are lowercase and may contain spaces (`front end`), which is why a
# line is parsed by SLICING the fixed field rather than by searching for
# whitespace. The first version of this checker used a regex and rejected
# `front end  <value>` -- a two-word label a shipping board emits -- which
# is how the spec's silence about spaces in labels got noticed at all.
LABEL_RE = re.compile(r"^[a-z][a-z0-9 ._-]*$")


def registry_path(explicit=None):
    """Where the token registry lives.

    NOT IN THIS REPOSITORY. The spec and the checker are general and meant to
    be public; a registry is a list of what one organization actually runs,
    which is a different kind of document. Publishing the spec should not
    publish an index of somebody's projects.

    So the path comes from the caller, or $WHOAMI_TOKENS, and the file shipped
    here is an .example carrying placeholders only.
    """
    return (explicit or os.environ.get("WHOAMI_TOKENS")
            or os.path.join(REPO, "tokens.example.txt"))


def load_tokens(path=None):
    """token -> unit count, from the registry."""
    path = registry_path(path)
    out = {}
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 2:
                try:
                    out[parts[0]] = int(parts[1])
                except ValueError:
                    out[parts[0]] = None
    except OSError:
        return None          # distinct from "empty": see check_tokens
    return out


def check_report(text, tokens, where="report"):
    """-> list of problem strings. Empty means conformant."""
    bad = []
    lines = text.splitlines()

    # Strip a trailing blank run; a report is allowed to end with a newline.
    while lines and not lines[-1].strip():
        lines.pop()

    if not lines:
        return ["%s: empty" % where]
    if len(lines) > MAX_LINES:
        return ["%s: %d lines, over the %d cap - refusing to read further"
                % (where, len(lines), MAX_LINES)]

    def field(i):
        """(label, value) for a grid line, or None.

        A SLICE, not a search. The label is the fixed field and the value is
        everything after it, so a label containing a space needs no escaping
        and there is nothing to infer about where it ends.
        """
        raw = lines[i]
        if len(raw) <= LABEL_WIDTH:
            return None                      # no value column at all
        label = raw[:LABEL_WIDTH].rstrip()
        value = raw[LABEL_WIDTH:].strip()
        if not label or not value:
            return None
        if raw[:LABEL_WIDTH] != label.ljust(LABEL_WIDTH):
            # Leading space, or padding that is not plain spaces.
            return ("!col", label, value)
        if len(label) >= LABEL_WIDTH:
            return ("!col", label, value)
        if not LABEL_RE.match(label):
            return ("!col", label, value)
        return (label, value)

    # ---- the preamble, which is frozen in every version that will exist ----
    f0 = field(0)
    if not f0 or f0[0] != "schema":
        bad.append("%s: line 1 is not a `schema` line; the preamble is frozen "
                   "and a reader cannot proceed without it" % where)
        return bad
    if f0[0] == "!col":
        bad.append("%s: line 1 label is not in the %d-column field"
                   % (where, LABEL_WIDTH))
        return bad

    m = SCHEMA_RE.match(f0[1].split()[0] if f0[1] else "")
    if not m:
        bad.append("%s: schema %r is not <major>.<4 digits> - a bare `1` or "
                   "`1.0` gives corrections nowhere to live, and an unpadded "
                   "revision is ambiguous" % (where, f0[1]))
        return bad
    major, revision = int(m.group(1)), int(m.group(2))
    if revision > 9999:
        bad.append("%s: revision %d is over 9999" % (where, revision))

    f1 = field(1) if len(lines) > 1 else None
    if not f1 or f1[0] != "speaks":
        bad.append("%s: line 2 is not a `speaks` line; without it a reader "
                   "that cannot parse this major has nothing to negotiate "
                   "with" % where)
        return bad
    if not SPEAKS_RE.match(f1[1].strip()):
        bad.append("%s: speaks %r is not a space-separated list of majors"
                   % (where, f1[1]))
        return bad
    speaks = [int(x) for x in f1[1].split()]
    # Obvious, and worth checking because an emitter that hardcodes one line
    # and computes the other can disagree with itself.
    if major not in speaks:
        bad.append("%s: emitted major %d but `speaks` is %s - a device that "
                   "just spoke a version necessarily speaks it"
                   % (where, major, speaks))

    # ---- the body ----
    seen = {}
    i = 2
    while i < len(lines):
        f = field(i)
        if f and f[0] == "!col":
            bad.append("%s: line %d: label %r is not in the %d-column field"
                       % (where, i + 1, f[1], LABEL_WIDTH))
            i += 1
            continue
        if not f:
            bad.append("%s: line %d is not a label/value line: %r"
                       % (where, i + 1, lines[i][:50]))
            i += 1
            continue

        label, value = f
        if label == "special":
            parts = value.split()
            if len(parts) < 2 or not parts[0].isdigit():
                bad.append("%s: line %d: special needs <count> <tag>"
                           % (where, i + 1))
                i += 1
                continue
            count, tag = int(parts[0]), parts[1]
            if not TAG_RE.match(tag):
                bad.append("%s: line %d: special tag %r is not a dotted name "
                           "with a prefix you own" % (where, i + 1, tag))
            if count > MAX_SPECIAL:
                bad.append("%s: line %d: special count %d is over the %d cap "
                           "- an unbounded count from the far end is a "
                           "request to read forever"
                           % (where, i + 1, count, MAX_SPECIAL))
                return bad
            if i + 1 + count > len(lines):
                bad.append("%s: line %d: special claims %d lines but only %d "
                           "remain - the count is what a reader skips on, so "
                           "an overrun is unrecoverable"
                           % (where, i + 1, count, len(lines) - i - 1))
                return bad
            i += 1 + count       # the block's content is opaque, by design
            continue

        if label in seen and label in REQUIRED:
            bad.append("%s: line %d: required field %r appears twice "
                       "(first at line %d)" % (where, i + 1, label,
                                               seen[label] + 1))
        seen[label] = i

        if label == "appid":
            bad += check_appid(value, tokens, where, i + 1)
        elif label == "attest":
            for meth in value.split():
                if meth not in KNOWN_ATTEST:
                    # NOT an error. SPEC.md: an unknown method is ignored, so
                    # that better hardware can advertise without a break.
                    pass
            if not value.split():
                bad.append("%s: line %d: attest is empty; use `none`"
                           % (where, i + 1))
        i += 1

    # A PREAMBLE AND NOTHING ELSE IS A REFUSAL, NOT A BROKEN REPORT.
    #
    # It is what a conformant device sends when asked for a major it cannot
    # speak, so listing six missing fields would describe a correct response
    # as six faults -- and bury the one thing the caller needs to read, which
    # is the `speaks` list it must now choose from.
    if not seen:
        return ["%s: negotiation refusal, not a report: device speaks %s"
                % (where, speaks)]

    for req in REQUIRED:
        if req not in seen and req not in ("schema", "speaks"):
            bad.append("%s: required field %r is missing" % (where, req))
    return bad


def check_refusal(text, want_major, where="refusal"):
    """A device's answer to a major it cannot speak.

    Conformant: the frozen preamble and nothing else. The checks are what
    SPEC.md calls the GREASE test -- ask for a version nobody implements and
    see whether negotiation has ever actually been exercised.
    """
    bad = []
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        return ["%s: empty - a device must answer, not go silent" % where]

    body = check_report(text, {}, where)
    is_refusal = any("negotiation refusal" in b for b in body)

    m = SCHEMA_RE.match(lines[0][LABEL_WIDTH:].strip().split()[0]
                        if len(lines[0]) > LABEL_WIDTH else "")
    if not m:
        return ["%s: no readable preamble; the one thing that is supposed to "
                "be readable under every major" % where]
    got_major = int(m.group(1))

    if got_major == want_major:
        bad.append("%s: asked for major %d and got it - pick a major the "
                   "device does NOT speak, or this tests nothing"
                   % (where, want_major))
    if not is_refusal:
        bad.append("%s: answered with a full report in major %d after being "
                   "asked for %d. The caller already said it cannot read "
                   "that; sending it anyway is the violation"
                   % (where, got_major, want_major))
    return bad


def check_appid(value, tokens, where, lineno):
    """appid <token> [unit <n>] fw <version>"""
    bad = []
    parts = value.split()
    if len(parts) < 3:
        return ["%s: line %d: appid needs at least `<token> fw <version>`"
                % (where, lineno)]

    token = parts[0]
    if not TOKEN_RE.match(token):
        bad.append("%s: line %d: token %r is not lowercase-hyphenated"
                   % (where, lineno, token))

    # `fw` LAST, so a parser can take the final field without knowing whether
    # `unit` was present. Checking the position is checking the property that
    # makes the rule worth having.
    if parts[-2] != "fw":
        bad.append("%s: line %d: `fw <version>` must be last; got %r"
                   % (where, lineno, " ".join(parts[-2:])))

    rest = parts[1:-2]
    units = None if tokens is None else tokens.get(token)
    if rest:
        if len(rest) != 2 or rest[0] != "unit" or not rest[1].isdigit():
            bad.append("%s: line %d: expected `unit <n>` between token and "
                       "fw; got %r" % (where, lineno, " ".join(rest)))
        elif units == 1:
            bad.append("%s: line %d: %r has one unit in the registry, so the "
                       "`unit` field must be omitted rather than read 1 "
                       "forever" % (where, lineno, token))
    elif units is not None and units > 1:
        bad.append("%s: line %d: %r has %d units registered, so `unit <n>` is "
                   "required to tell them apart" % (where, lineno, token, units))

    if tokens is not None and token not in tokens:
        bad.append("%s: line %d: token %r is not in the registry - an "
                   "unregistered token is how two applications end up "
                   "claiming one name" % (where, lineno, token))
    return bad


def check_tokens(explicit=None):
    path = registry_path(explicit)
    if not os.path.isfile(path):
        # A missing registry is a FAILURE, not a pass. A check that cannot
        # find its data must say so rather than report clean.
        print("  registry not found at %s - refusing to report clean" % path)
        print("  pass a path, or set WHOAMI_TOKENS")
        return 1
    print("  registry: %s" % path)
    seen, bad = {}, []
    for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if not TOKEN_RE.match(parts[0]):
            bad.append("line %d: %r is not lowercase-hyphenated" % (n, parts[0]))
        if parts[0] in seen:
            bad.append("line %d: %r already registered at line %d - this is "
                       "the collision the registry exists to prevent"
                       % (n, parts[0], seen[parts[0]]))
        seen[parts[0]] = n
        if len(parts) < 3:
            bad.append("line %d: expected `<token> <units> <where>`" % n)
        elif not parts[1].isdigit():
            bad.append("line %d: units %r is not a number" % (n, parts[1]))
    for b in bad:
        print("  " + b)
    print("  %d token(s), %d problem(s)" % (len(seen), len(bad)))
    return 1 if bad else 0


def spec_revision(text):
    m = re.search(r"^Schema version \*\*(\d+)\.(\d{4})\*\*", text, re.M)
    return (int(m.group(1)), int(m.group(2))) if m else None


def check_spec():
    """The revision gate: SPEC.md changed without the revision moving."""
    path = os.path.join(REPO, "SPEC.md")
    try:
        now = open(path, encoding="utf-8").read()
    except OSError as e:
        print("  cannot read SPEC.md: %s" % e)
        return 1

    cur = spec_revision(now)
    if cur is None:
        print("  SPEC.md has no `Schema version **X.YYYY**` line")
        return 1

    p = subprocess.run(["git", "-C", REPO, "show", "HEAD:SPEC.md"],
                       capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        print("  no committed SPEC.md to compare against (first commit); "
              "revision %d.%04d" % cur)
        return 0

    was = spec_revision(p.stdout)
    if p.stdout == now:
        print("  SPEC.md unchanged; revision %d.%04d" % cur)
        return 0
    if was == cur:
        print("  SPEC.md CHANGED but the revision is still %d.%04d." % cur)
        print("  Bump it. Nothing parses differently because of that number,")
        print("  so it is only true for as long as something checks.")
        return 1
    print("  SPEC.md changed, revision %d.%04d -> %d.%04d" % (was + cur))
    return 0


# ---------------------------------------------------------------- selftest --
# The selftest runs against tokens.example.txt and names only example tokens.
# It has to be self-contained: a public repository whose own tests need a
# private registry to pass is a repository nobody else can check out and run.
GOOD = """schema     1.0000
speaks     1
appid      example-sensor fw 0.23.0
project    Example Sensor
board      some-board
built      Nov 19 2026 17:02:11   (this firmware)
uptime     0d 02:50:17
attest     none"""

CASES = []


def case(should_fail, label, text):
    CASES.append((should_fail, label, text))


case(False, "minimal conformant report", GOOD)
case(False, "extras after the required set",
     GOOD + "\nfront end  some-frontend")
case(False, "unknown attest method is ignored, not rejected",
     GOOD.replace("attest     none", "attest     se050-p256"))
case(False, "unit field where the registry says several units",
     GOOD.replace("appid      example-sensor fw 0.23.0",
                  "appid      example-display unit 2 fw 3.3.0"))
case(False, "special block skipped whole",
     GOOD + "\nspecial    2 note.operator\nanything at all\neven: colons")
case(False, "a special line inside a block is just content, not nesting",
     GOOD + "\nspecial    2 note.operator\nspecial    9 note.fake\nsecond")

# These exist only to show it still fires.
case(True, "no schema line at all", GOOD.split("\n", 1)[1])
case(True, "schema not first", "speaks     1\n" + GOOD)
case(True, "bare integer revision", GOOD.replace("1.0000", "1"))
case(True, "unpadded revision", GOOD.replace("1.0000", "1.12"))
case(True, "speaks missing", GOOD.replace("speaks     1\n", ""))
case(True, "emitted major not in speaks",
     GOOD.replace("speaks     1", "speaks     2 3"))
case(True, "required field missing",
     GOOD.replace("board      some-board\n", ""))
case(True, "fw not last in appid",
     GOOD.replace("example-sensor fw 0.23.0",
                  "example-sensor fw 0.23.0 unit 1"))
case(True, "unregistered token",
     GOOD.replace("example-sensor", "totally-made-up"))
case(True, "unit field on a single-unit token",
     GOOD.replace("example-sensor fw", "example-sensor unit 1 fw"))
case(True, "multi-unit token with no unit field",
     GOOD.replace("example-sensor", "example-display"))
case(True, "special count overruns the end",
     GOOD + "\nspecial    9 note.operator\nonly one line")
case(True, "special count over the cap",
     GOOD + "\nspecial    99999 note.operator")
case(True, "label out of the 11-column field",
     GOOD.replace("board      some-board", "board   some-board"))
case(True, "uppercase label", GOOD.replace("board      ", "Board      "))
case(True, "duplicate required field", GOOD + "\nuptime     0d 00:00:01")
case(True, "label fills the whole field, leaving no separator",
     GOOD + "\nelevenchars value")
case(False, "label with a space, which a shipping board emits",
     GOOD + "\nfront end  some-frontend (a two-word label)")

# The GREASE path: what a device sends when asked for a major it cannot
# speak. These go through check_refusal() rather than check_report().
REFUSALS = []


def refusal(should_fail, label, text, want=9999):
    REFUSALS.append((should_fail, label, text, want))


refusal(False, "preamble only, the conformant refusal",
        "schema     1.0002\nspeaks     1")
refusal(True, "a full report instead of a refusal", GOOD)
refusal(True, "silence - a device must answer, not go quiet", "")
refusal(True, "garbage with no readable preamble",
        "ERROR: unknown command\n??\n")
refusal(True, "the requested major came back, so the test proved nothing",
        "schema     9999.0000\nspeaks     9999", 9999)


def selftest(explicit=None):
    tokens = load_tokens(explicit)
    if tokens is None:
        print("  cannot read the registry at %s - the selftest would be "
              "testing nothing" % registry_path(explicit))
        return 1
    bad = 0
    for should_fail, label, text in CASES:
        problems = check_report(text, tokens, "case")
        failed = bool(problems)
        ok = failed == should_fail
        if not ok:
            bad += 1
        print("  %-4s %-6s %s" % ("ok" if ok else "FAIL",
                                  "REJECT" if should_fail else "accept", label))
        if not ok and problems:
            print("        got: %s" % problems[0][:88])
        if not ok and not problems:
            print("        got: accepted, but this case exists to be rejected")
    print("  -- negotiation refusals (the GREASE path) --")
    for should_fail, label, text, want in REFUSALS:
        problems = check_refusal(text, want, "case")
        ok = bool(problems) == should_fail
        if not ok:
            bad += 1
        print("  %-4s %-6s %s" % ("ok" if ok else "FAIL",
                                  "REJECT" if should_fail else "accept", label))
        if not ok and problems:
            print("        got: %s" % problems[0][:88])
        if not ok and not problems:
            print("        got: accepted, but this case exists to be rejected")

    total = len(CASES) + len(REFUSALS)
    fires = sum(1 for c in CASES if c[0]) + sum(1 for r in REFUSALS if r[0])
    print("\n  %d cases, %d of them existing only to show it still fires, "
          "%d failed" % (total, fires, bad))
    return 1 if bad else 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    # --tokens <path> may appear anywhere; it names the registry.
    explicit = None
    if "--tokens" in argv:
        i = argv.index("--tokens")
        if i + 1 >= len(argv):
            print("  --tokens needs a path")
            return 2
        explicit = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if not argv:
        print(__doc__)
        return 0

    cmd = argv[0]
    if cmd == "--selftest":
        return selftest(explicit)
    if cmd == "tokens":
        return check_tokens(explicit)
    if cmd == "spec":
        return check_spec()
    if cmd == "report":
        if len(argv) < 2:
            print("  report needs at least one file")
            return 2
        tokens = load_tokens(explicit)
        if tokens is None:
            print("  registry unreadable at %s - refusing to report clean"
                  % registry_path(explicit))
            return 1
        rc = 0
        for path in argv[1:]:
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError as e:
                print("  %s: %s" % (path, e))
                rc = 1
                continue
            problems = check_report(text, tokens, os.path.basename(path))
            for p in problems:
                print("  " + p)
            if problems:
                rc = 1
            else:
                print("  %s: conformant" % os.path.basename(path))
        return rc
    print("  unknown command %r" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
