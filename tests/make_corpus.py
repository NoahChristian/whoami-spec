"""Generate the shared conformance corpus.

SPDX-License-Identifier: MIT

WHY A CORPUS AND NOT A TEST SUITE PER LANGUAGE. There are now many reader
implementations of this format. Each one hand-testing itself is the exact
failure this repository exists to undo: the first three implementations of the
EMITTER were each tested, all three passed, and all three shared a defect,
because a thing tested only against itself is tested against its own
assumptions.

So the expectations live here, once, in a language-neutral form, and every
implementation is judged against the same bytes. An implementation that passes
is not merely self-consistent; it agrees with the others.

THE FORMAT IS DELIBERATELY STUPID. Two files per case:

  <name>.report   the exact bytes a reader is handed
  <name>.expect   `key=value` lines, split on the FIRST `=`

No JSON, no YAML, no library. A runner in Java or Rust should not need a
dependency to read the corpus, and a dependency is one more thing that can
disagree between languages. Splitting on the first `=` is enough because a
label may contain a space but never an equals sign.

EXPECTATIONS ARE HAND-WRITTEN FROM SPEC.md, not captured from a parser. Recording
what an implementation currently does would make the corpus agree with the bug.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "corpus")

GOOD = (
    "schema     1.0005\n"
    "speaks     1\n"
    "appid      example-sensor fw 0.23.0\n"
    "project    Example Sensor\n"
    "board      some-board\n"
    "built      Nov 19 2026 17:02:11\n"
    "uptime     0d 02:50:17\n"
    "attest     none\n"
)

CASES = []


def case(name, report, why, **expect):
    CASES.append((name, report, why, expect))


# ---------------------------------------------------------------- good reads

case("good", GOOD,
     "The baseline. Every required field, one major, nothing unusual.",
     status="ok", major="1", revision="5", speaks="1", refusal="false",
     blocks="0", **{"field.appid": "example-sensor fw 0.23.0",
                    "field.project": "Example Sensor",
                    "field.attest": "none"})

case("two-word-label",
     GOOD + "front end  some-frontend\n",
     "THE CASE THAT CATCHES A PARSER SPLITTING ON WHITESPACE. The grid is "
     "fixed-width precisely so a label may contain a space. A reader that "
     "searches for the first space reports the label as `front` and moves "
     "`end` into the value -- a corrupted read that looks successful.",
     status="ok", refusal="false",
     **{"field.front end": "some-frontend"})

case("appid-with-unit",
     GOOD.replace("example-sensor fw 0.23.0",
                  "example-display unit 2 fw 3.3.0"),
     "`fw` is last so a reader can take the final field without knowing "
     "whether `unit` was present.",
     status="ok", **{"field.appid": "example-display unit 2 fw 3.3.0"})

case("multi-speaks",
     GOOD.replace("speaks     1\n", "speaks     1 2 3\n"),
     "A device that can emit several majors declares all of them, so a reader "
     "that has fallen behind discovers it rather than never learning.",
     status="ok", speaks="1 2 3", refusal="false")

case("crlf", GOOD.replace("\n", "\r\n"),
     "Serial consoles emit CRLF. A reader that only accepts LF fails on real "
     "hardware while passing every test written on a workstation.",
     status="ok", major="1", refusal="false",
     **{"field.attest": "none"})

case("refusal", "schema     4.0001\nspeaks     3 4\n",
     "A REFUSAL IS A SUCCESSFUL READ. The device cannot speak the requested "
     "major, so it answers with the frozen preamble alone -- the one answer a "
     "reader of any major is guaranteed to understand. Treating this as a "
     "parse failure throws away the only diagnosable thing about it.",
     status="ok", major="4", revision="1", speaks="3 4", refusal="true")

case("special-skipped",
     GOOD + "special    2 note.operator\n"
            "attest     forged\n"
            "anything at all\n"
            "hostname   real-value\n",
     "SECURITY-RELEVANT. Block content is opaque and must be SKIPPED by count, "
     "never parsed. A reader that parses inside a block lets the far end forge "
     "any field it likes -- here, `attest`. The field after the block must "
     "still be read, proving the reader resynchronized exactly.",
     status="ok", blocks="1",
     **{"field.attest": "none", "field.hostname": "real-value"})

case("special-unknown-tag",
     GOOD + "special    1 vendor.acme.whatever\nopaque line\n",
     "Not knowing a tag is the EXPECTED case, not an error. The count is all "
     "a reader needs; it skips and continues without warning.",
     status="ok", blocks="1", refusal="false")

case("empty-value", GOOD + "fault      \n",
     "A field with an empty value is readable, not malformed. Refusing it "
     "would make a board delete a field rather than report nothing.",
     status="ok", **{"field.fault": ""})

# ------------------------------------------------- reads that must be refused

case("empty", "",
     "Nothing to read.", status="error", error="empty")

case("no-preamble", "appid      x fw 1\n",
     "The preamble is the contract. Without it a reader cannot know what "
     "major the rest is in, so there is nothing safe to do with the body.",
     status="error", error="preamble")

case("schema-short-revision", "schema     1.12\nspeaks     1\n",
     "The revision is FOUR digits, zero-padded, always. Fixed width is what "
     "makes 1.0012 and 1.0002 compare correctly as text; accepting 1.12 "
     "accepts a report no conformant emitter produces.",
     status="error", error="schema")

case("unpadded-label", "schema  1.0005\nspeaks  1\n",
     "Mis-padding is NOT tolerated, deliberately. The fixed width is what "
     "lets a label hold a space, so a reader that falls back to splitting on "
     "whitespace to be helpful reinstates the two-word-label bug.",
     status="error", error="preamble")

case("special-count-too-big", GOOD + "special    9999 x.y\n",
     "BOUND THE COUNT. An unbounded count supplied by the far end is a "
     "request to read forever. Past the cap it is a malformed report, not an "
     "instruction to obey.",
     status="error", error="special")

case("special-count-overflow", GOOD + "special    99999999999 x.y\n",
     "A count that would wrap is still a count the far end chose. Cap the "
     "LENGTH before converting, or the wrap produces a small number that "
     "looks reasonable.",
     status="error", error="special")

case("special-count-negative", GOOD + "special    -1 x.y\n",
     "Not a non-negative decimal. A signed read here is how a -1 becomes a "
     "very large unsigned skip.",
     status="error", error="special")

case("line-flood", "schema     1.0005\nspeaks     1\n" + "x y\n" * 600,
     "BOUND THE REPORT. A device stuck in a loop must be a failed read rather "
     "than a growing buffer.",
     status="error", error="bounds")

case("no-newline", "schema " + "A" * 900,
     "A device that never sends a newline must not be able to hang a reader. "
     "The preamble's whole value is that the decision is cheap.",
     status="error", error="bounds")


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    index = []
    for name, report, why, expect in CASES:
        with open(os.path.join(OUT, name + ".report"), "wb") as fh:
            fh.write(report.encode("utf-8"))
        lines = ["# " + why.replace("\n", " ")]
        for key in sorted(expect):
            lines.append("%s=%s" % (key, expect[key]))
        with open(os.path.join(OUT, name + ".expect"), "wb") as fh:
            fh.write(("\n".join(lines) + "\n").encode("utf-8"))
        index.append(name)
    with open(os.path.join(OUT, "INDEX"), "wb") as fh:
        fh.write(("\n".join(index) + "\n").encode("utf-8"))
    good = sum(1 for c in CASES if c[3].get("status") == "ok")
    print("  wrote %d cases (%d read, %d refused) to %s"
          % (len(CASES), good, len(CASES) - good, OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
