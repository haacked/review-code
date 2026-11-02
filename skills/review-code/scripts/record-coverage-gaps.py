#!/usr/bin/env python3
"""Write every reviewer coverage gap into a review as a "Not verified" section.

A gap is work a reviewer could not finish, such as a run against the real
database. The compose step used to restate gaps in prose, and a gap it left out
disappeared from the review. This script copies each gap verbatim from the
retained coverage files instead.

The section carries a marker naming the session whose coverage it lists.
Re-running for the same session replaces that section. Sections from other
sessions, which a full --append review or a delta merge leaves above, stay.

Output (stdout):

    {"count": 2, "written": true}
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "helpers"))

from markdown_fences import walk_fences  # noqa: E402

HEADING = "## Not verified"
PREAMBLE = (
    "Reviewers in this run could not finish this work. Nothing here was "
    "checked, so treat each item as open until someone runs it."
)
TOP_HEADING = re.compile(r"^ {0,3}#{1,2}\s")
LINT_NOTES = re.compile(r"^ {0,3}##\s+Lint notes\s*$")


def marker_for(session: str) -> str:
    return f"<!-- coverage-gaps: {session} -->"


def load_gaps(coverage_dir: Path) -> list[tuple[str, str]]:
    gaps = []
    for path in sorted(coverage_dir.glob("*.json")):
        coverage = json.loads(path.read_text(encoding="utf-8"))
        for gap in coverage.get("gaps", []):
            gaps.append((path.stem, " ".join(gap.split())))
    return gaps


def strip_section(lines: list[str], marker: str) -> tuple[list[str], int | None]:
    """Remove this session's section and return where it started."""
    prose = [index for index, _, kind in walk_fences(lines) if kind == "prose"]
    start = next(
        (
            index
            for index in prose
            if lines[index].strip() == HEADING
            and index + 1 < len(lines)
            and lines[index + 1].strip() == marker
        ),
        None,
    )
    if start is None:
        return lines, None
    end = next(
        (index for index in prose if index > start and TOP_HEADING.match(lines[index])),
        len(lines),
    )
    return lines[:start] + lines[end:], start


def insertion_point(lines: list[str]) -> int:
    """Place a new section before a trailing Lint notes section.

    A Lint notes section with another section after it belongs to an earlier
    run of a full --append review, so the new section goes at the end.
    """
    headings = [
        index
        for index, line, kind in walk_fences(lines)
        if kind == "prose" and TOP_HEADING.match(line)
    ]
    if headings and LINT_NOTES.match(lines[headings[-1]]):
        return headings[-1]
    return len(lines)


def render(gaps: list[tuple[str, str]], marker: str) -> list[str]:
    lines = [HEADING, marker, "", PREAMBLE, ""]
    lines.extend(f"- `{reviewer}`: {gap}" for reviewer, gap in gaps)
    return lines + [""]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--review-file", required=True, type=Path)
    parser.add_argument(
        "--coverage-dir",
        required=True,
        type=Path,
        help="The retained coverage directory, <review>.artifacts/<session>/coverage",
    )
    args = parser.parse_args()
    try:
        if not args.coverage_dir.is_dir():
            raise ValueError(f"coverage directory not found: {args.coverage_dir}")
        gaps = load_gaps(args.coverage_dir)
        marker = marker_for(args.coverage_dir.resolve().parent.name)
        lines = args.review_file.read_text(encoding="utf-8").splitlines()
        lines, start = strip_section(lines, marker)
        if gaps:
            at = insertion_point(lines) if start is None else start
            if at > 0 and lines[at - 1].strip():
                lines.insert(at, "")
                at += 1
            lines[at:at] = render(gaps, marker)
        if gaps or start is not None:
            while lines and not lines[-1].strip():
                lines.pop()
            tmp = args.review_file.with_name(f".{args.review_file.name}.gaps")
            try:
                tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
                os.replace(tmp, args.review_file)
            finally:
                tmp.unlink(missing_ok=True)
        print(json.dumps({"count": len(gaps), "written": bool(gaps)}))
    except (OSError, ValueError) as error:
        parser.exit(1, f"record coverage gaps: {error}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
