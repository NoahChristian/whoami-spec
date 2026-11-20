# whoami

An identity report an embedded device emits so a host can answer *what am I
holding* without probing it to find out.

---

## The schema

**Schema `1.0005`.** This is the whole format:

```
schema     1.0005
speaks     1
appid      example-display unit 2 fw 3.3.0
project    Example Display, unit 2
board      some-board/soc/core
built      Nov 19 2026 18:07:46   (this firmware)
uptime     0d 00:00:24
attest     none
```

A report is a sequence of lines. **The label is columns 1–11, right-trimmed.
The value is column 12 onward, left-trimmed.**

Parsing a line is a **slice, not a search for whitespace**. That is what lets a
label contain a space — `front end` — with nothing to escape and nothing to
infer. A reader that splits on the first space reads that label as `front` and
silently moves `end` into the value: a corrupted read that looks like a
successful one. Two of the reference implementations had this bug, and the
shared test corpus is what found it.

A label is lowercase and at most 10 characters, so the field always holds it
plus a separating space. Unknown labels are **data, not errors**.

### `schema <major>.<revision>` — line 1, frozen

The revision is **four digits, zero-padded, always**. Written `1.5` nobody can
tell revision 5 from revision 5000, and the two orderings disagree. It is a
counter and never a float: as a float `1.0010` and `1.001` collapse onto one
value.

- **A new `revision`** fixes wording or an implementation bug. Nothing parses
  differently; no device needs reflashing.
- **A new `major`** may change everything after line 2.

### `speaks <major> ...` — line 2, frozen

Every major this device can emit, space-separated. Declaring one is free;
emitting an older one costs flash, and no device is obliged to.

**These two lines have the same grammar under every schema version that will
ever exist.** That is the whole mechanism: a reader meeting a major it cannot
parse still learns *which* one it met and *what else* it could have asked for —
a diagnosable answer instead of a parse failure.

### Negotiating — the caller declares first

```
host   -> whoami 2
device -> schema 2.0003
          speaks 1 2 3
          ...the body, in major 2...
```

The device answers **in the major it was asked for**, not in its own newest.
Sending a newer body to a caller that has already said it reads major 2 is the
violation, not a kindness: that caller then needs a code path for bytes it
cannot parse, running on input from a device whose identity is by definition not
yet established. Refusing removes the path instead of hardening it.

**When the device cannot speak the requested major, it sends the preamble alone
and stops:**

```
host   -> whoami 2
device -> schema 4.0001
          speaks 3 4
```

That is a **successful read**, not an error. Test it with a version nobody
implements — `whoami 9999` — and watch it stop after two lines. It is the path
that otherwise runs for the first time on the day a new major ships.

### Required fields

| Field | Value |
|---|---|
| `schema` | `<major>.<revision>`, first line, frozen grammar |
| `speaks` | majors this device can emit, second line, frozen grammar |
| `appid` | `<token> [unit <n>] fw <version>` — `fw` **last**, so a parser takes the final field without knowing whether `unit` was present |
| `project` | human-readable name |
| `board` | build target or hardware identifier |
| `built` | when **this firmware** was compiled |
| `uptime` | time since boot |
| `attest` | what the device could offer to prove the report; `none` is valid and common |

Recommended where the platform has them, with these spellings: `hostname`,
`image`, `signed`, `core`, `reset`, `previous`, `fault`, `coredump`.

- **`built` is this firmware; `core` is what it was built against** and did not
  compile. One board reported its prebuilt core's date as `built` and so
  claimed September for an image compiled in November.
- **`reset` is why this boot happened; `previous` is why the last run ended.**
  The second cannot be derived from the first, because restarting a board to
  fix it destroys the evidence of what broke it.

Anything else is an **extra**, permitted after the required fields.

### `special <count> <tag>` — saying something the schema never defined

```
special    2 note.operator
CT clamp on L2 was reseated 2026-11-19, readings before that are suspect
next calibration due at the spring meter read
```

A counted run of lines this schema does not define and does not need to. The
reader knows exactly how far to skip because the count says so, whether or not
it has heard of the tag — **a length is what turns an unknown thing from a
desync into a shrug.**

Content is opaque: no grid, no escaping, no nesting. A reader that does not know
the tag skips `count` lines and continues; not understanding a block is the
expected case, not an error. Nothing in a block may be load-bearing — a block is
how you *say* something, not how you *agree* on something.

This is what keeps a private exchange between two parties from forcing a major
bump that every third party must implement and no third party wants.

---

## Reading one safely

A report arrives from something not yet identified. **Every number in it is
input, not instruction** — including the counts that say how far to read.

- **Bound the preamble read.** At most two lines and a few hundred bytes before
  deciding. A device that never sends a newline must not be able to hang a
  reader.
- **Bound the `special` count**, and cap its *length* before converting it, so a
  value that would wrap never becomes a small number that looks reasonable.
- **Bound the whole report**, so a device stuck in a loop is a failed read
  rather than a growing buffer.
- **Skip blocks by count; never parse inside one.** A reader that parses block
  content lets the far end forge any field it likes, `attest` included.
- **Treat every field as untrusted text until attested.** `appid` is a *claim* —
  anything that can answer on the port can make it. It is enough to stop you
  driving the wrong board by accident; it is not enough to decide anything that
  matters.
- **Never execute, path-join or shell-interpolate a field.** Match a token
  against a known list; do not build a filename from it.
- **Classify errors by token or type, never by message text.** A message is for
  a human and may be reworded.

The shape of all of these: the format tells a reader how far to read, and the
reader decides how far it is willing to. Both halves are required. **A length
you trust without a bound is not a safety feature, it is an instruction.**

---

## What is in here

| | |
|---|---|
| [`SPEC.md`](SPEC.md) | the specification, with the reasoning and the prior art |
| [`CHANGELOG.md`](CHANGELOG.md) | what changed, and **what each change cost to adopt** |
| [`ref/`](ref/) | one emitter and ten readers — see [`ref/README.md`](ref/README.md) |
| [`tests/corpus/`](tests/corpus/) | 18 cases, hand-written from the spec |
| [`tools/whoami_check.py`](tools/whoami_check.py) | the conformance checker |

```sh
pwsh -File tests/run_all.ps1          # every implementation, same 18 cases
python tools/whoami_check.py report captured.txt
python tools/whoami_check.py --selftest
```

A missing toolchain is reported **skipped**, never as a pass. A runner that did
not run has said nothing about its implementation.

### Implementations

C/C++ · Python (MicroPython subset) · JavaScript · TypeScript · Ruby · Rust
(`core` only) · Java · R · Julia · MATLAB · PowerShell

They are **vendored, not depended on**: copy the files you need. A build that
requires a neighboring clone breaks for anyone who has only one of the pair,
and silently changes what every consumer compiles when the neighbor is edited.
Keep vendored copies honest by byte-comparing them in CI — two copies that must
agree and are never checked are one copy and one liability.

### Why there is a reference at all

The format was implemented three times by hand before any of this existed. All
three were tested, all three passed, and all three shared a defect: each did I/O
on the request path, one of them a 31 KB flash CRC on every call to an ungated
HTTP endpoint.

The bug was in none of the three. **It was in there being three.** A
specification that describes only output leaves the *structure* to be rebuilt per
board, and a rebuilt structure is a re-derived set of bugs. A conformance checker
catches format drift; it cannot catch implementations being independently
expensive, because expensive is conformant.

Eleven implementations is that same problem scaled up — unless all of them are
judged against the same bytes by something other than themselves. The corpus is
hand-written from the spec rather than captured from a parser, because capturing
would make it agree with the bug.

---

## The registry is yours, not this document's

`appid` tokens are not listed here. The spec and its checker are general; a list
of what one organization actually runs is a different kind of document, and
publishing a format should not publish an index of somebody's projects.

Point the checker at your own list:

```sh
python tools/whoami_check.py tokens --tokens <your-registry>/tokens.txt
# or set $WHOAMI_TOKENS
```

[`tokens.example.txt`](tokens.example.txt) carries placeholders only — generated
by blanking every value, never by copying a working file.

## Claiming conformance

> conforms to whoami schema **1.0005** or any later revision of major 1

"Or lower" is not safe: an earlier revision may describe a field this
implementation does not emit.

## License

MIT — see [LICENSE.md](LICENSE.md). Every file in `ref/`, `tests/` and `tools/`
carries an `SPDX-License-Identifier: MIT` header, so a vendored copy keeps its
license with it rather than leaving it behind in this repository.
