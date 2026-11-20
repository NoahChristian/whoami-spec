# Reference core

`whoami_core.c` / `whoami_core.h` — the parts of a whoami report that are not
platform-specific: the frozen preamble, the 11-column grid, the appid grammar,
the required-field order, and the major negotiation.

## Why this exists

The format was implemented three times by hand before this was written. All
three then turned out to share a defect — each did I/O on the request path, one
of them a 31 KB flash CRC on every call to an ungated HTTP endpoint. The bug was
not in any of the three implementations. It was in there being three.

A specification that describes only output leaves the structure to be rebuilt
per board, and a rebuilt structure is a re-derived set of bugs. The conformance
checker catches format drift; it cannot catch three implementations being
independently expensive, because expensive is conformant.

## What it does not do

It cannot read a reset reason, an image header or a crash dump, because those
differ per platform and are exactly what the caller supplies. It allocates
nothing, knows no RTOS, and emits through one callback the caller provides.

The caller assembles `struct whoami_info` **once, at init** — not per request.
That is the design lesson from the defect above, expressed as an interface: a
struct of ready values makes the cheap thing the easy thing to do.

## Vendoring, not a build dependency

Copy both files into the consuming project. Do **not** make this repository a
required sibling checkout: a build that needs a neighboring clone breaks for
anyone who has only one of the pair, and silently changes what every consumer
compiles when the neighbor is edited.

The copies are kept honest by assertion rather than by discipline — compare them
byte-for-byte in a pre-commit hook or CI step, the same way any other duplicated
tool on a bench should be. Two copies that must agree and are never checked are
one copy and one liability.

## Conformance

The core emits the preamble itself, so the schema version in a report is the
version of the code that produced it, rather than a constant someone remembered
to bump. Feed a captured report to `tools/whoami_check.py` to verify the whole
line set, including the platform's own extra fields.
