# Changelog

What changed in the schema, and **what each change cost to adopt**.

The second column is the point. A format change is not free: every device
that emits it needs a reflash and every tool that reads it needs an edit, and
those rounds are easy to spend without noticing. Recording the cost beside
the change is what makes "is this worth a version" a question with evidence
behind it rather than a matter of taste.

Entries are newest first. A major bump lists every implementation that had to
move; a revision lists only what was corrected, because by definition a
revision changes no parsing and costs no reflash.

---

## Reference implementations — 2026-11-19 (schema unchanged, still 1.0005)

**NOT A SCHEMA CHANGE, and deliberately not given a revision number.** No
grammar changed, no field was added or removed, nothing parses differently, and
no device needs a reflash.

It was drafted as `1.0006` and that was wrong. A revision number is a statement
about the wire format, and the wire format did not move — the repository gained
code. Numbering it would have obliged every board to be reflashed to emit a new
number for no behavioral reason, which is precisely the cost the second column
of this file exists to discourage. The version a device reports should change
when what it emits changes, and not when its author has been busy.

Recorded here anyway, because "what shipped and when" is the other question
this file answers.

**What prompted it.** The format had been implemented three times by hand. All
three were tested, all three passed, and all three shared a defect: each did
I/O on the request path, one of them a 31 KB flash CRC on every call to an
ungated HTTP endpoint. The bug was in none of the three implementations; it was
in there being three. A spec that describes only output leaves the structure to
be rebuilt per board, and a rebuilt structure is a re-derived set of bugs.

Added:

- **`ref/`** — one emitter and ten readers: C/C++, Python (MicroPython subset),
  JavaScript, TypeScript, Ruby, Rust (`core` only), Java, R, Julia, MATLAB and
  PowerShell.
- **`tests/corpus/`** — 18 cases, hand-written from this document rather than
  captured from any parser. Capturing would have made the corpus agree with the
  bug.
- **`tests/run_all.ps1`** — runs every implementation against those bytes and
  reports a missing toolchain as `skipped`, never as a pass.

**The corpus paid for itself before it was committed.** It found that two
implementations — the two written first and reviewed most — split a line on the
first whitespace instead of slicing at column 12, so the label `front end` was
read as `front` with `end` silently moved into the value. A corrupted read that
looks like a successful one, which is the failure this format's fixed-width
grid exists to make impossible. It also caught a PowerShell bound that threw a
language error instead of refusing, on precisely the input it was written to
stop: a guard that did not guard.

**What this does not change.** Conformance is still decided by
`tools/whoami_check.py`, which is stricter than any reader here. A reader in
the field must cope with reports it would also have called non-conformant, so
reading and validating stay separate on purpose.

---

## 1.0005 — 2026-11-19

The name is settled. **Cost to adopt:** none; nothing renamed.

`whoareyou` is the semantically correct question from the host's side, and
was considered. `whoami` is kept because the command is typed into the
device's own shell, where the device is the actor and reports on itself —
which is what Unix `whoami` does. It reads backwards only in the protocol
line, and that is this document's framing rather than a fault in the name.

Renaming would have cost three reflashes of live hardware, a repository
rename and a spec-wide edit, to correct something that is right where it is
used. Recorded here so the question is closed rather than relitigated.

---

## 1.0004 — 2026-11-19

Prior art corrected: it was overstated in one place and missing the most
obvious citation in another.

**Cost to adopt:** none. Documentation only.

**Modbus was demoted.** 1.0003 called FC 43 / MEI 14 "the closest functional
analogue", which gave a 2004 protocol credit for a pattern far older than it.
SCSI INQUIRY (ANSI X3.131-1986) returns vendor, product and revision in ASCII
fields, and IEEE 488.2's `*IDN?` answers with comma-separated manufacturer,
model, serial and firmware revision — the `appid` line's content, decades
earlier. Modbus is now cited only for its named conformity levels, with the
note that tiered capability levels are a generic idea owing nothing to it.

**The section now says these are precedent, not ancestry.** Most are
convergent; the problem is narrow enough that independent designs land in the
same place, and claiming descent from whichever one the author happened to
read is a tidier story than the truth.

**And the command this format is named after was missing entirely.** Unix
`whoami` first appeared in 2BSD, shorthand for the Berkeley `who am i`, from
`who` in Version 6 AT&T UNIX. It answers *which user am I running as* — the
actor's identity, not the machine's. The Unix command matching this
document's content is `uname`.

The name is kept because on a board with no users and no sessions the device
is the actor, so "who am I" and "what am I" are the same question — but that
is now written down rather than left to look like an unconsidered borrowing.

---

## 1.0003 — 2026-11-19

Prior art cited, the wrong-major response named as a violation, and a
required conformance test for negotiation.

**Cost to adopt:** none for emitters already conformant — all three additions
write down rules that were implied. But it adds a **test** every
implementation must now pass, and an implementation that fails it was always
broken; the test only makes that visible.

**Answering in a major the caller did not request is the violation.** Asked
for major 2, a device has two correct answers: a major-2 report, or the
preamble alone. Emitting its own newest instead sends the caller something it
has already said it cannot read, and a reader must reject such a response
unread rather than salvage fields from it.

**The GREASE test is required, not suggested.** Ask a device for a major
nobody implements — `whoami 9999` — and it must return the preamble and stop:
no hang, no body, no closed port. Negotiation is the one path that runs only
on the day a new major ships, so an implementation that has never been asked
for a version it lacks has never had that path exercised. TLS learned this
expensively: servers intolerant of unknown versions forced insecure
downgrade-retries and broke negotiation so thoroughly that TLS 1.3 had to
freeze its version field and negotiate in an extension instead.

The checker gained `check_refusal()` and five cases for it. It also now
reports a preamble-only response as **"negotiation refusal, not a report"**
rather than listing six missing fields — describing a correct answer as six
faults buried the one thing the caller needs, which is the `speaks` list.

**Prior art is now cited**, because a format that silently reinvents an
existing convention looks arbitrary and leaves the next reader nowhere to go:

- **CANopen DS301 object 0x1018** splits a 32-bit revision into two 16-bit
  halves — upper for behavior changes, lower for unchanged behavior. That is
  this document's major/revision split with the same semantics, arrived at
  independently, and it is why the revision is specified as a `uint16`.
- **Modbus FC 43 / MEI 14** is the closest functional analogue, and its
  conformity levels are this document's profile concept.
- **RFC 6763** requires its version attribute to be the first key/value pair
  and requires unknown keys to be silently ignored — the same two rules.

**And one deliberate departure, recorded rather than assumed.** Modbus answers
a request above its conformity level *at the level it has*. This document
refuses and returns the preamble. Modbus is friendlier and has decades of
field evidence, and is right for its case: its levels are nested, so a lower
level still answers the question. Majors here are not nested — a different
major may be a different format — so "answer at the level I have" would mean
emitting something the caller cannot parse. The friendlier behavior would be
the unsafe one here.

---

## 1.0002 — 2026-11-19

Says how conformance is claimed, and moves the registry out of this
repository.

**Cost to adopt:** none. No emitter changes and no reflash — both additions
write down rules that were already implied.

**Conformance is claimed differently by emitters and readers**, which had
been left to guesswork:

- an emitter states one version — `emits whoami schema 1.0002` — because it
  produces exactly one thing and "or greater" is a claim it cannot keep;
- a reader states a major — `reads whoami major 1` — because the revision
  never changes parsing, so naming one is meaningless precision.

**"Or lower" is not safe**, and the example is this document's own 1.0001. A
revision may resolve an AMBIGUITY, and output legal under the clarified
wording was not illegal before — it was undefined. A reader written against
the earlier text may have guessed a stricter rule. The first checker did
exactly that about labels containing spaces. So the obligation falls on
readers: be permissive about anything the spec does not explicitly forbid.

**The registry left this repository.** The spec and checker are general and
meant to be public; a registry is an index of what one organization actually
runs, and publishing a format should not publish that. `tokens.example.txt`
carries placeholders; the checker takes `--tokens <path>` or `$WHOAMI_TOKENS`.

The selftest was rewritten to name only example tokens. It had been using
real bench ones, which would have left a public repository whose own tests
cannot pass without a private file — something nobody else could check out
and run.

---

## 1.0001 — 2026-11-19

A label may contain a space, and a line is parsed by slicing the fixed field
rather than by searching for whitespace.

**Cost to adopt:** none. No emitter changes, no reflash, no parser rewrite —
this is a clarification of what the fixed-width field already meant, which is
what a revision is for.

**Found by writing the checker**, which is the useful part. The first version
used a regex assuming labels were single tokens, and rejected
`front end  <value>` — a two-word label a shipping board emits today. The
spec had simply never said whether a label could contain a space, and the
ambiguity was invisible until something tried to parse against it.

The fix removes a clause rather than adding one: with the label defined as
columns 1-11, a space inside it needs no escaping and there is nothing left
to infer. The old "one space minimum between label and value" rule is gone,
replaced by a 10-character ceiling on labels so the separator always exists.

**The revision gate fired on its own first use.** Editing SPEC.md without
bumping the number was caught by `whoami_check.py spec`, which is the only
evidence worth having that the gate works.

---

## 1.0000 — 2026-11-19

First published schema.

**Shipped by:** nothing yet. The three implementations this format was
written for emit a pre-schema report — no `schema` line, no `speaks`, no
`attest`, and `appid` outside the label grid. They are schema 0 by this
document's reckoning and each needs one firmware change to conform.

**Cost to adopt:** three firmware changes, three flashes, and one detection
tool, which matches an `appid` substring and keeps working unchanged because
padding does not break a substring match.

**What it settles, so these do not get relitigated:**

| Decision | Why |
|---|---|
| major = the format, revision = corrections only | a bare integer makes every clarification a breaking change, or unrecorded |
| revision is 4 digits, 0-9999, `uint16` | room nobody rations; max value off the type boundary |
| zero-padded, split on the dot, never a float | `1.12` is ambiguous; `2.10` as a float is `2.1` |
| preamble (lines 1-2) frozen forever | negotiation is impossible if a reader cannot find the version under an unknown major |
| caller declares its major first, as a MUST | a body in a language the reader does not speak is attack surface, not an inconvenience |
| `special <count> <tag>` blocks | lets one source and one sink exchange something without a major bump every third party must implement |
| `attest` is a capability list, unknown methods ignored | hardware with a secure element extends without a format break |

**Known gaps at publication:** no conformance checker yet, so nothing
enforces any of the above — including the rule that an edit to `SPEC.md`
bumps the revision. Until that exists this document is a specification with
no gate, which this bench has repeatedly found to mean a specification that
drifts.
