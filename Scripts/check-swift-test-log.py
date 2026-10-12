#!/usr/bin/env python3
"""Reject failed or incomplete Swift Testing runs, even if swift test exits zero."""
import re
import sys
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
COMPLETION = re.compile(r"Test run with ([1-9][0-9]*) tests(?: in [0-9]+ suites?)? passed\b")
FAILURE = re.compile(r"recorded an issue|(?:Test|Suite|Test run) .*\bfailed(?: after| with| at|\.)")


def validate(text):
    lines = ANSI.sub("", text).splitlines()
    failures = [line for line in lines if FAILURE.search(line)]
    if failures:
        raise ValueError("Swift Testing recorded failure: " + failures[0])
    summaries = [index for index, line in enumerate(lines) if COMPLETION.search(line)]
    if len(summaries) != 1:
        raise ValueError("Expected one completed, passing Swift Testing run; found " + str(len(summaries)))
    if any(re.search(r"(?:Test|Suite) .*started\.", line) for line in lines[summaries[0] + 1:]):
        raise ValueError("Swift Testing started more tests after its completion summary")


def main():
    try:
        validate(Path(sys.argv[1]).read_text(errors="replace"))
    except (OSError, ValueError) as error:
        print("Swift test completion guard: " + str(error), file=sys.stderr)
        return 1
    print("Swift test completion guard: complete passing run confirmed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
