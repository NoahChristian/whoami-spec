# whoami — a board identity report

Schema version **1.0005**.

A format any embedded application can emit so that a host can answer "what am
I holding" without guessing, and later "is this really that device" without a
second format.

## Why this exists

Enumeration does not identify an application. Every Zephyr CDC device
enumerates as `2FE3:0004`, so vendor and product identify the RTOS and nothing
else; a USB-serial bridge identifies the bridge. On 2026-11-16 one board's
shell output was read as another's for several minutes because the only way to
tell them apart was to send a command and judge the reply.

That probing is the hazard, not an inconvenience:

- **It requires talking to an unidentified device.** Whatever you send, you
  send to something you have not identified yet.
- **On some hardware the act of opening the port is destructive.** A bridge
  that drives `EN` from `DTR`/`RTS` resets the board, so enumerating a meter
  interrupts it — and the reset is indistinguishable afterwards from a power
  cut.

So identity has to be answerable cheaply, in a form that does not depend on
the transport that happens to be in doubt, and it has to say how much it can
be trusted.

## Two axes, and keeping them apart

| | What it is | How it moves |
|---|---|---|
| **Schema** | the grammar and the required fields | rarely, deliberately, this document |
| **Profile** | what one implementation offers — optional sections, attestation methods | per app, per firmware revision |

A report states both. A reader uses the schema to parse and the profile to
decide what it may ask for next. Conflating them is what forces a format
change every time one device gains a capability.

## Grammar

A report is a sequence of lines. Each line is a label, left-aligned in an
11-character field, then the value:

```
schema     1.0000
speaks     1
appid      example-display unit 2 fw 3.3.0
project    Example Display, unit 2
board      some-board/soc/core
built      Nov 19 2026 18:07:46   (this firmware)
uptime     0d 00:00:24
attest     none
```

- **The first two lines are a frozen preamble.** See below. Everything after
  them is defined by the major version and may be a completely different
  format.
- **The label is columns 1 to 11, right-trimmed. The value is column 12
  onward, left-trimmed.** Parsing a line is a slice, not a search for
  whitespace — which is what lets a label contain a space (`front end`)
  with no escaping and no ambiguity about where it ends.
- A label is lowercase and **at most 10 characters**, so the field always
  holds it plus at least one separating space. Eleven characters or more is
  not conformant: it would put the value hard against the label and force
  every reader back to guessing where the boundary is, which is the thing the
  fixed width exists to prevent.
- Values are free text unless a field says otherwise. Parenthetical asides
  are permitted at the end of a value and carry no meaning.
- Unknown labels are **data, not errors**. See compatibility.

## The preamble, and why it can never change

```
schema     <major>.<revision>
speaks     <major> [<major> ...]
```

**These two lines have the same grammar in every schema version that will
ever exist.** Not "should" — the negotiation below is impossible without it.

A major version means *a reader that does not know it cannot read the report*:
the labels, the order, even the line structure may be different. But a reader
must still be able to discover **which** version it is looking at and **what
else the device could say instead**. If the preamble were versioned with the
rest, a schema-2 reader meeting a schema-4 device could not locate either
fact, and the only possible response would be to give up without being able
to say why.

So lines 1 and 2 are carved out. Nothing may be added to them, reordered
within them, or given new meaning in a later version. Everything else is free.

### `schema <major>.<revision>`

```
schema     1.0000
schema     1.0012
schema     2.0000
```

- **The major is the format.** A different major is a different language. A
  reader that does not know it must not attempt to parse the body — not
  "parse what it recognizes", because under a different major a familiar
  label may mean something else entirely.
- **The revision is corrections only**, and is **always four digits,
  zero-padded**, counting from `0000`. Bug fixes, clarified wording, a field
  whose description was ambiguous. A revision never adds, removes, renames or
  re-orders a field. Any reader that knows major N can read every N.xxxx,
  past and future, without adjustment — `1.0012` and `2.0000` are a break;
  `1.0000` and `1.0012` are not, however many corrections lie between them.
- **Four digits, 0 to 9999, held as a `uint16`. SETTLED — do not reopen.**

  It is two integers split on a dot, so the range was a free choice and the
  choice was argued rather than defaulted:

  - Ten thousand revisions per major is room for every clarification anyone
    will ever file, so nobody ever feels a fix "costs" a version. The whole
    point of splitting the halves is that the cheap half is free to use; a
    counter people ration is a counter people skip, and then the fix ships
    unlabeled.
  - **Not 65535**, although `uint16` would hold it, because that puts the
    maximum legal value exactly on the storage type's boundary — which is
    where off-by-one and overflow bugs live. 9999 leaves headroom by
    construction, so no implementation can be right at 9998 and wrong at the
    maximum.
  - Nothing larger. An unreachable range is an untested range.

  Revisiting this costs a reflash of every device and an edit to every
  parser. That is a real price, it is tracked in `CHANGELOG.md`, and it is
  why the number is written down here as decided rather than as current.
- **Zero-padded because the width is what removes the ambiguity.** Written
  `1.12`, nobody can tell whether that is revision 12 or revision 1200 — and
  the two orderings disagree. Fixed width means there is nothing to infer.
- **Never compare these as a floating-point number.** `2.10` as a float is
  `2.1`, so `2.10` and `2.1` collapse onto one value and `2.9` sorts above
  `2.10`. Split on the dot and compare two integers; the revision is a plain
  counter in the range 0–9999, not a decimal fraction. The dotted form is a
  presentation, not an arithmetic type, and treating it as one is a silent
  wrong answer rather than an error.
- Exhausting `9999` within one major is not a version problem, it is a sign
  the major has been carrying changes that were never corrections.

**What the revision is actually for, since nothing parses differently because
of it.** It is diagnostic, in the same way `built` is diagnostic beside `fw`:
it answers "is this device carrying the correction we made after that bug",
which the major alone cannot. A reader must never branch on it.

**And it will go unbumped unless something checks.** A number nothing reads
and nothing enforces stops being maintained — this bench has watched a
one-line commit rule go unobserved for 107 commits for exactly that reason,
and a spelling rule survive only once it had a gate. So the conformance
checker treats an edit to this document without a revision bump as a failure.
That is the feedback loop; without it the field is decoration that decays
into a lie.

### `speaks <major> ...`

Every major version this device can emit on request, space-separated. A
device that only knows its own writes just that one.

Emitting an older major costs flash on the constrained side of the link, so
no device is obliged to. But declaring it is free, and a reader that knows the
device cannot meet it can say so precisely instead of reporting a parse
failure.

### Negotiating — the asker declares first

**The caller states the major it speaks, and the device answers in that
major.** It does not answer in its own newest and leave the caller to cope.

```
host   -> whoami 2
device -> schema 2.0003
          speaks 1 2 3
          ...the rest of the report, in major 2...
```

A device running major 3 does not emit major 3 here. It has been told the
caller speaks 2, so sending 3 would be sending something the caller has
already said it cannot read — a wasted round trip at best, and at worst a
body the caller mis-parses because a familiar label meant something else in
the newer format.

The `speaks` line still appears, so the caller can see it could have asked for
more. That is how a tool discovers it has fallen behind, rather than never
learning.

**When the device cannot speak the requested major**, it answers with the
preamble alone and stops:

```
host   -> whoami 2
device -> schema 4.0001
          speaks 3 4
```

The caller can always read that, because the preamble is frozen. It now has
both lists and can say "this device speaks 3, 4; I know 1, 2" — a diagnosable
answer rather than a parse failure. The preamble doing double duty as the
negotiation-failure response is the reason it is worth freezing two lines
rather than one.

### Why this is a MUST and not a convenience

**A body in a language the reader does not speak is attack surface.**

If a device may answer in whatever major it likes, then every reader needs a
code path that does *something* with bytes it cannot parse — skip, guess,
partially decode, resynchronize. That path runs on unvalidated input from a
device whose identity has by definition not been established yet, it is the
least exercised code in the reader, and it is reachable by anything that can
answer on the port. A report claiming major 99 with a body crafted against a
reader's fallback logic is a plausible attack and an implausible thing to
have tested.

Negotiating first removes the path rather than hardening it. If the caller
names its major and the device answers only in that major, then the only
bytes a reader ever processes without a parser are the two frozen preamble
lines.

So:

- A device **must not** emit a body in a major the caller did not ask for.
- A reader **must not** parse a body whose major it did not request. It reads
  the preamble and stops.
- A tool **must** name its major. Not "should".

**A bare `whoami`** — no major — is the human form and emits the device's own
newest. It exists for a person at a console, whose parser is their eyes. It is
the one case where an unconstrained version comes back, which is exactly why a
tool may not use it.

### Answering in the wrong major is the violation

Asked for major 2, a device has exactly two correct answers:

1. a report in major 2, or
2. the preamble alone, saying what it does speak.

**Answering in major 9999 is not a third option.** The caller has already
stated it speaks 2; sending it something else is sending a body it has said
it cannot read. A reader **must reject such a response unread** — not attempt
it, not salvage fields from it. The version was requested, so a mismatch is a
misbehaving or hostile device, and the only safe handling is to stop.

This is the rule that keeps "unparsed bytes never reach a parser" true in
practice rather than in principle.

### Testing it: ask for a version nobody implements

Implementations that mishandle an unknown version are invisible until the day
a new major ships — which is the most expensive day to discover them. TLS
learned this the hard way: servers that rejected unrecognized version numbers
forced browsers into insecure downgrade-retries, which broke negotiation so
badly that TLS 1.3 had to freeze the old version field and move the real
negotiation into an extension. The countermeasure that followed, GREASE, is
to send reserved nonsense values deliberately so intolerant implementations
fail early, in testing, rather than late, in the field.

The equivalent here is one line:

```
host   -> whoami 9999
device -> schema <its own>.<revision>
          speaks <its own majors>
```

A conformant device returns the preamble and stops. It must not hang, must
not emit a body, must not close the port, and must not emit its own newest
report as though the request had been bare.

**This is a required conformance test, not a suggestion.** An implementation
that has never been asked for a version it does not have is an implementation
whose negotiation has never been exercised, and negotiation is the one path
that only runs on the day it matters.

A reader should keep parsers for every major it has ever supported rather than
dropping old ones. Devices in the field do not update together, and the reader
is the cheap side to keep compatible: it has a filesystem and a package
manager, and the thing it is talking to has neither.

### `appid`

```
appid <token> [unit <n>] fw <version>
```

- `token` — lowercase, hyphen-separated, unique across every application that
  emits this format. **It is a contract.** Scripts match on it to decide which
  device they are holding; renaming one breaks detection silently, which is
  the worst way for it to break. Registered in `tokens.txt`.
- `unit` — present only where a project has several physical units. A project
  with one board omits it rather than writing `unit 1` forever, because a
  field that is always the same value trains readers to ignore it.
- `fw` — **last**, so a parser can take the final whitespace-separated field
  without knowing whether `unit` was present.

### `attest`

```
attest <method> [<method> ...]
```

What this implementation **can** offer, strongest first; `none` if it can
offer nothing. This is a capability declaration, not a claim about the
current report — the report itself is unauthenticated by definition, because
anything that can answer on a port can produce one.

Defined methods:

| Method | Meaning |
|---|---|
| `none` | no proof of identity is available from this device |
| `ecdsa-p256` | will sign a challenge with a per-device P-256 key whose public half is enrolled |

A reader that does not recognize a method **ignores that method** and uses the
strongest it does know, down to treating the report as `none`. That is what
lets a device with better hardware advertise a better method without breaking
every existing reader.

### The challenge exchange

Optional, and defined here so it does not get invented three different ways:

```
host   -> whoami attest <method> <nonce>
device -> attest <method> <base64 signature>
```

- `nonce` is at least 16 bytes of host randomness, base64. The device must not
  accept a repeated nonce it has already signed in this boot.
- The signature covers the **exact bytes of the report** the device would emit
  now, followed by the decoded nonce. Signing the report rather than the nonce
  alone is what makes the attested answer about the *content*, not merely
  about possession of a key.
- The host verifies against the public key enrolled for that `token` and
  `unit`. The enrollment list is public by design: it is a trust anchor, not
  a secret, and may be copied freely.

**What this does and does not buy.** It defeats something on the network
pretending to be the device. It does not defeat an attacker with physical
access unless the private key is held somewhere that physical access cannot
reach — a secure element, or flash encryption with secure boot. An
implementation that keeps its key in plain flash should still advertise
`ecdsa-p256`: the method is honest about what it proves, and a reader that
needs more should be checking the profile, not the method name.

## Required and optional fields

Required in schema 1 — a report missing any of these is not conformant:

| Field | Value |
|---|---|
| `schema` | `<major>.<revision>`, revision four digits zero-padded, first line, frozen grammar |
| `speaks` | majors this device can emit, second line, frozen grammar |
| `appid` | as above |
| `project` | human-readable name, free text |
| `board` | build target or hardware identifier |
| `built` | when THIS firmware was compiled |
| `uptime` | time since boot |
| `attest` | capability list, `none` permitted |

Recommended where the platform has them, with these spellings — a field that
exists under two names across two boards is the problem this document is for:

`hostname`, `image`, `signed`, `core`, `reset`, `previous`, `fault`,
`coredump`.

- **`built` is this firmware; `core` is what it was built against** and did
  not compile — an RTOS version, a vendor SDK, a prebuilt library set. These
  are different questions and one board reporting the second under the first
  is how a sketch compiled in November reports September.
- **`reset` is why this boot happened; `previous` is why the last run ended.**
  The second cannot be derived from the first, because the act of restarting a
  board to fix it destroys the evidence of what broke it.

Anything else is an **extra** and is always permitted after the required
fields. Extras are how a board says something only it can say. A spec that
forbade them would make implementers delete useful output to conform.

## Special blocks — saying something the schema never defined

```
special    <count> <tag>
<count lines of anything>
```

A counted run of lines that this schema does not define and does not need to.
The reader knows exactly how far to skip because the count says so, whether or
not it has ever heard of the tag.

```
special    2 note.operator
CT clamp on L2 was reseated 2026-11-19, readings before that are suspect
next calibration due at the spring meter read
```

This is the same mechanism the RS485 link on this bench already uses, for the
same reason: its frame header carries a length, so a receiver that has never
heard of a frame type still knows how many bytes to jump. A length is what
turns an unknown thing from a desync into a shrug.

**What it is for.** A message meaningful to one source and one sink —
an operator's note, a line from a build system, a vendor's diagnostic — without
making every other implementation learn about it. Without this, anything two
parties want to exchange forces a major bump that every third party must then
implement and no third party cares about.

Rules:

- `count` is the number of lines that follow, exactly. Not bytes, not
  including the `special` line itself.
- `tag` is a dotted name. Use a prefix you own (`note.`, `vendor.acme.`). A
  tag with no prefix is reserved for this spec.
- **Content is opaque.** No label grid, no required structure, no escaping —
  a line inside a block is whatever the source put there. The count is the
  only thing a reader needs.
- **No nesting.** A `special` line inside a block is just one of its lines. A
  nested form would mean a reader that skips a block must still parse it to
  count correctly, which defeats the point.
- A reader that does not know the tag **skips `count` lines and continues**.
  It does not warn and it does not fail; not understanding a block is the
  expected case, not an error.
- Blocks carry no meaning for conformance. A report is conformant on its
  required fields alone.
- **Nothing in a block may be load-bearing.** If an implementation needs a
  reader to act on something, that belongs in a field, in a major version, in
  this document. A block is how you say something; it is not how you agree on
  something.

## Claiming conformance

**An emitter states one version. A reader states a major.** They are opposite
claims and the same phrasing does not fit both.

```
emits whoami schema 1.0001          <- a board, a firmware, a tool that prints one
reads whoami major 1                <- a parser, a detector, a test harness
```

- **An emitter produces exactly one thing**, so "1.0001 or greater" is a claim
  it cannot keep — it emits what its code emits. The precise revision is what
  tells you whether it carries a given correction.
- **A reader accepts a range**, and by the rules above the revision never
  changes parsing — so a reader claiming `1.0001` specifically is meaningless
  precision. It reads all of major 1, and that is what it should say.

### "or lower" is not safe, and here is the failure

A revision may resolve an **ambiguity**. Output that is legal under the
clarified wording was not illegal before — it was undefined — so a reader
written against the earlier text may have guessed a stricter rule and will
reject it.

That is not hypothetical. This document's own 1.0001 clarified that a label
may contain a space. The first conformance checker written against 1.0000 had
assumed labels were single tokens, and rejected `front end  <value>` — a
two-word label a shipping board emits. The emitter was never wrong; the
reader was stricter than the spec had ever required.

So the obligation falls on readers:

> **Be permissive about anything the spec does not explicitly forbid.** A
> reader that invents a restriction will break on a revision that writes the
> real rule down, and the breakage will look like a non-conformant device.

An emitter does not claim backward conformance to earlier revisions, and
nothing should ask it to.

## The registry is yours, not this document's

Every implementer keeps a token registry; **this repository does not publish
one.** `tokens.example.txt` carries placeholders and nothing else.

The format is general and meant to be read by anyone. A registry is a list of
what one organization actually runs, and a published spec should not come
with an index of somebody's projects attached. The checker takes the path as
data — `--tokens <path>`, or `$WHOAMI_TOKENS` — so the two can live in
different places with different visibility.

What a registry must do is in `tokens.example.txt`'s own header: one line per
application, units recorded, renames kept as retired entries rather than
deleted.

## Compatibility, in one table

| Situation | What the reader does |
|---|---|
| device can speak the major you asked for | parse normally; its revision never changes parsing |
| device cannot — preamble only comes back | fail, naming both version lists |
| device answered in a major you did not ask for | reject the body unread; this is a misbehaving or hostile device |
| unknown label, requested major | ignore it; it is an extra |
| unknown `special` tag | skip `count` lines, continue |
| unknown `attest` method | ignore that method, use the best it knows |

The shape every row shares: **an extension a reader does not understand costs
it nothing**, because in each case the format tells it how to get past the
part it cannot read — the major tells it to stop, the count tells it how far
to jump, the list tells it what else to ask for.

Two obligations on implementers that nothing can check for them:

- **A device must not claim a major it does not implement.** Claiming a
  version is cheaper than implementing one, and a reader has no way to verify
  the claim before trusting it.
- **A new major must be a real incompatibility.** Bumping it for an addition
  that could have been an extra or a `special` block forces every reader to
  grow a parser for no gain, and the next real break then arrives in a
  version nobody has implemented.

## Transports

The same field names and semantics apply wherever the report is produced — a
serial console, an HTTP endpoint, a structured document. A JSON rendering uses
the labels as keys:

```json
{"schema": "1.0002", "appid": "example-sensor fw 0.23.0", "attest": "none"}
```

The format is about what is said, not where. A board reachable only over the
network and a board reachable only over a wire should answer the same
questions in the same words.

## Reading one safely

A report arrives from something that has not been identified yet — that is
what it is for. Every number in it is therefore input, not instruction.

- **Bound the preamble read.** At most two lines and a few hundred bytes
  before deciding. A device that never sends a newline must not be able to
  hang the reader, and the preamble's whole value is that the decision is
  cheap.
- **Bound the `special` count.** Cap how many lines a reader will skip, and
  treat anything past the cap as a malformed report rather than obeying it.
  An unbounded count supplied by the far end is a request to read forever.
  This is the same guard the RS485 link on this bench keeps as `LINK_MAX_LEN`
  — a length past a sane bound is not a long frame, it is noise that happened
  to contain a sync pattern.
- **Bound the report.** A total line cap, so a device stuck in a loop is a
  failed read rather than a growing buffer.
- **Treat every field as untrusted text until attested.** `appid` is a claim.
  Anything that can answer on the port can make it. It is enough to stop you
  driving the wrong board by accident; it is not enough to decide anything
  that matters, and the `attest` exchange exists for the cases that do.
- **Never execute, path-join or shell-interpolate a field.** A token is
  matched against a known list, not used to construct a filename.

The shape of all of these: the format tells a reader how far to read, and the
reader decides how far it is willing to. Both halves are required. A length
you trust without a bound is not a safety feature, it is an instruction.

## Prior art, and where this agrees or departs

Nothing here is novel, and saying where it came from is worth more than
appearing original — a format that silently reinvents an existing convention
looks arbitrary, and the next reader has nowhere to go for the reasoning.

These are cited as **precedent, not ancestry**. Most are convergent: the
problem is narrow enough that independent designs land in the same place, and
claiming descent from whichever one you happened to read would be a tidier
story than the truth.

**The name is borrowed from Unix.** `whoami` first appeared in 2BSD as
shorthand for the Berkeley `who am i`, from `who` in Version 6 AT&T UNIX.
There it answers *which user am I running as* — the actor's identity, not the
machine's — so by content the closer Unix command is `uname`.

**Kept, and settled — do not reopen.** It is typed into the DEVICE'S OWN
shell, where the device is the actor and reports on itself, which is exactly
what Unix `whoami` does. It reads backwards only in the protocol line
(`host -> whoami 2`), and that is this document's framing, not the name's
fault: the request is named after the command, and the host is asking the
device to run it. `whoareyou` would read correctly in that one line and
wrongly at every prompt.

**And "ask a device on a bus who it is" is an old and obvious pattern** —
this document is a late instance of it, not a new idea. Two long-established
forms:

- **SCSI INQUIRY**, ANSI X3.131-1986, returns ASCII vendor identification,
  product identification and product revision level in fixed-width fields.
- **IEEE 488.2 `*IDN?`** answers with comma-separated manufacturer, model,
  serial number and firmware revision — the `appid` line's content, in one
  line, decades earlier.

**CANopen DS301, Identity Object 0x1018.** Its 32-bit revision number is two
16-bit halves: the upper changes when behavior changes, the lower changes
when behavior is unchanged. That is this document's major/revision split with
the same semantics — the one convergence specific enough to be worth noting
rather than merely old, and the reason the revision here is a `uint16` rather
than left open. Sub-indices 1 to 4 carry vendor ID, product code, revision
and serial, which is the `appid` line's job in a different encoding.

**Modbus, function 43 / MEI type 14, Read Device Identification**, is a
later instance — it arrived around 2004 — and is cited here only because its
named *conformity levels* (basic, regular, extended) are the closest thing in
a published protocol to this document's profile concept. Tiered capability
levels are a generic idea with many independent inventions; nothing about
this is owed to Modbus.

> **Where this departs, deliberately.** Modbus answers a request above a
> server's conformity level *at the level it actually has*. This document
> returns the preamble and stops.
>
> That is right for Modbus because its levels are **nested** — a lower level
> is a subset of a higher one, so answering at the lower level still answers
> the question. Majors here are **not** nested: a different major may be a
> different format, so "answer at the level I have" would mean emitting
> something the caller has already said it cannot parse. The friendlier
> behavior would, in this format, be the unsafe one.

**DNS-SD, RFC 6763.** Reached the same two conclusions in normative language:
§6.7 requires the version attribute `txtvers` to be *the first key/value pair
in the TXT record*, and §6.3 says that if an implementation sees unknown keys
it *MUST silently ignore them*. Version first, unknowns ignored.

**TLS version negotiation, and its failure.** Servers that rejected
unrecognized version numbers forced insecure downgrade-retries and broke
negotiation badly enough that TLS 1.3 froze the legacy version field and moved
the real negotiation into an extension. Two things follow for this document:
the caller-declares-first rule, which keeps a device from ever being handed a
version unsolicited; and the GREASE-style conformance test above, because
intolerance bugs are invisible until the day they are expensive.

**USB string descriptors** identify an application only as far as it is
willing to be honest, and are not a control. They are a convenience tier:
useful for telling your own devices apart at enumeration without opening a
port, worthless for deciding anything that matters.

## Disclosure

A report is readable by anything that can reach the device, so what goes in
one is a decision rather than a default.

- **Identity before trust is the point.** `appid` must be readable without
  credentials, or it cannot be used to decide what you are talking to — which
  is the one thing it is for.
- **A precise firmware version tells a reader which known defects apply.** On
  a device with a reachable fault that is a targeted attack, not a banner.
  Emitting it is still usually right, because the remedy for a known defect is
  to fix it rather than to hide the version — but it is a decision to take
  knowingly, and an implementation may offer the precise version only over an
  attested exchange.
- **Never in a report**: credentials, keys, tokens, network addresses, MAC
  addresses, or anything derived from them.
