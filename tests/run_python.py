"""Run the shared corpus against ref/python/whoami.py.

SPDX-License-Identifier: MIT

Every language's runner does exactly this and prints the same shape, so the
results can be compared line for line. The corpus is the authority; a runner
that disagrees with it is reporting a defect in its implementation, not a
difference of opinion.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CORPUS = os.path.join(HERE, "corpus")
sys.path.insert(0, os.path.join(REPO, "ref", "python"))

import whoami  # noqa: E402

# Map this implementation's error text to the corpus's canonical token. Each
# language keeps its own wording -- a reader's message should read naturally in
# its own idiom -- and only the token has to agree.
TOKENS = (
    ("empty", "empty"),
    ("preamble", "preamble"),
    ("schema", "schema"),
    ("special", "special"),
    ("exceeded", "bounds"),
)


def canonical(message):
    for needle, token in TOKENS:
        if needle in message:
            return token
    return "unmapped:" + message


def load_expect(path):
    out = {}
    with open(path, "rb") as fh:
        for raw in fh.read().decode("utf-8").split("\n"):
            if not raw or raw.startswith("#"):
                continue
            eq = raw.find("=")      # FIRST equals: a label may contain a space
            if eq < 0:
                continue
            out[raw[:eq]] = raw[eq + 1:]
    return out


def check(name):
    with open(os.path.join(CORPUS, name + ".report"), "rb") as fh:
        report_bytes = fh.read()
    expect = load_expect(os.path.join(CORPUS, name + ".expect"))
    problems = []

    try:
        report = whoami.parse(report_bytes)
        status = "ok"
    except whoami.WhoamiError as exc:
        report, status = None, "error"
        got = canonical(exc.status)
        if expect.get("status") != "error":
            problems.append("raised %r but the case expects a successful read"
                            % exc.status)
        elif "error" in expect and got != expect["error"]:
            problems.append("error token %r, corpus says %r" % (got, expect["error"]))

    if expect.get("status") == "error" and status == "ok":
        problems.append("read succeeded, but this case exists to be refused")

    if report is not None:
        for key, want in sorted(expect.items()):
            if key in ("status", "error"):
                continue
            if key.startswith("field."):
                label = key[len("field."):]
                got = report.get(label)
                if got != want:
                    problems.append("field %r is %r, corpus says %r"
                                    % (label, got, want))
            elif key == "major" and str(report.major) != want:
                problems.append("major %s, corpus says %s" % (report.major, want))
            elif key == "revision" and str(report.revision) != want:
                problems.append("revision %s, corpus says %s" % (report.revision, want))
            elif key == "speaks":
                got = " ".join(str(m) for m in report.speaks)
                if got != want:
                    problems.append("speaks %r, corpus says %r" % (got, want))
            elif key == "refusal":
                got = "true" if report.refusal else "false"
                if got != want:
                    problems.append("refusal %s, corpus says %s" % (got, want))
            elif key == "blocks" and str(report.special_blocks) != want:
                problems.append("blocks %s, corpus says %s"
                                % (report.special_blocks, want))
    return problems


def main():
    with open(os.path.join(CORPUS, "INDEX"), "rb") as fh:
        names = [n for n in fh.read().decode("utf-8").split("\n") if n.strip()]
    bad = 0
    for name in names:
        problems = check(name)
        if problems:
            bad += 1
        print("  %-4s %s" % ("ok" if not problems else "FAIL", name))
        for problem in problems:
            print("        %s" % problem)
    print("\n  python: %d cases, %d failed" % (len(names), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
