# Reference implementations

One emitter and ten readers, each holding to the same 18-case corpus in
[`../tests/corpus/`](../tests/corpus/).

| Language | Files | Emits | Reads |
|---|---|---|---|
| C / C++ | `c/whoami_core.{c,h}`, `c/whoami_parse.{c,h}` | yes | yes |
| Python / MicroPython | `python/whoami.py` | yes | yes |
| JavaScript | `js/whoami.mjs` | yes | yes |
| TypeScript | `ts/whoami.ts` | yes | yes |
| Ruby | `ruby/whoami.rb` | yes | yes |
| Rust | `rust/whoami.rs` | — | yes |
| Java | `java/Whoami.java` | — | yes |
| R | `r/whoami.R` | — | yes |
| Julia | `julia/Whoami.jl` | — | yes |
| MATLAB | `matlab/whoami_parse.m` | — | yes |
| PowerShell | `powershell/Whoami.psm1` | — | yes |

```
pwsh -File tests/run_all.ps1
```

Every implementation it cannot run is reported **skipped**, never as a pass. A
runner that did not run has said nothing about its implementation, and a
summary that counts it green is a false clean.

## Why there is a core at all

The format was implemented three times by hand before any of this existed. All
three were tested. All three passed. All three shared a defect: each did I/O on
the request path, one of them a 31 KB flash CRC on every call to an ungated
HTTP endpoint.

The bug was not in any of the three. It was in there being three.

A specification that describes only output leaves the *structure* to be rebuilt
per board, and a rebuilt structure is a re-derived set of bugs. The conformance
checker catches format drift; it cannot catch three implementations being
independently expensive, because expensive is conformant.

## Why the corpus matters more than the implementations

Eleven implementations is that same duplication problem, scaled up — unless
they are all judged against the same bytes by someone other than themselves.
Each one testing itself would reproduce the original failure exactly: a thing
tested only against itself is tested against its own assumptions.

So the expectations live in one place, hand-written from `SPEC.md` rather than
captured from any parser. Recording what an implementation currently does would
make the corpus agree with the bug.

It has already earned this. Writing the corpus caught a real defect in two
implementations at once — both split a line on the first whitespace instead of
slicing at column 12, so the label `front end` was read as `front` with `end`
moved into the value. A corrupted read that looks like a successful one, in the
two implementations written first and reviewed most. It also caught a
PowerShell bound that threw a language error instead of refusing, on the exact
input it existed to stop.

## What every implementation agrees on

- **A line is a SLICE, never a whitespace search.** Columns 1–11 are the label,
  right-trimmed; column 12 onward is the value, left-trimmed. The fixed width
  is what lets a label contain a space with no escaping.
- **No regular expressions on untrusted input.** A reader whose safety rests on
  a backtracking pattern is one crafted report away from the denial of service
  the bounds exist to prevent.
- **Counts are bounded before they are obeyed**, and length-capped before they
  are converted, so a value that would wrap never becomes a small number that
  looks reasonable.
- **A refusal is a successful read.** A device that cannot speak the requested
  major answers with the frozen preamble alone. That is the one answer a reader
  of any major is guaranteed to understand, and treating it as a parse failure
  throws away the only diagnosable thing about it.
- **Block content is skipped by count, never parsed.** A reader that parses
  inside a `special` block lets the far end forge any field it likes.
- **Errors are classified by token or type, never by message text.** A message
  is for a human and may be reworded; the token is the contract.

## Vendoring, not a build dependency

Copy the files you need into the consuming project. Do **not** make this
repository a required sibling checkout: a build that needs a neighboring clone
breaks for anyone who has only one of the pair, and silently changes what every
consumer compiles when the neighbor is edited.

Keep the copies honest by assertion rather than by discipline — compare them
byte-for-byte in a pre-commit hook or CI step. Two copies that must agree and
are never checked are one copy and one liability.

## Notes per language

- **C** is the one that ends up on a microcontroller. Its only external
  symbols are `snprintf`, `strlen`, `memcmp` and `memset`; it allocates
  nothing and the parser borrows the caller's buffer.
- **Python** is written to the MicroPython subset — no `re`, no `dataclasses`,
  no `enum`, no f-strings — so it runs on a board as well as a workstation.
- **Rust** uses only `core` and fixed-size arrays, so a `no_std` crate takes it
  unchanged. It does not declare `#![no_std]` itself, because that is a
  crate-level attribute and would stop the file being used as a module.
- **MATLAB** returns fields in a `containers.Map`, not a struct: `front end` is
  not a valid field name, and a struct would force mangling the label or
  dropping the field.
- **Julia** works on bytes throughout, because Julia indexes strings by byte
  offset and throws on a non-boundary index — a report carrying an unexpected
  byte should be a field problem, not a `StringIndexError`.
