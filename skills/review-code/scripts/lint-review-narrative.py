#!/usr/bin/env python3
"""Lint the narrative prose in a composed review and record what it finds.

The voice agent rewrites finding bodies and never sees the Overview or the
per-agent summaries, so that prose is the one place in a review nothing checks.
This script lints exactly that prose and, with --annotate, writes the warnings
into the review as a "Lint notes" section.

What counts as narrative is a whitelist: the body of `## Overview` and of every
`## <Something> Review` section, minus the finding blocks inside them. A finding
block runs from a paragraph opening with a severity prefix (`blocking:`,
`suggestion:`, `question:`, `nit:`) to the next thematic break or heading. Fix
Summary, Suggested Comments, tables, and the metadata header are skipped: the
first two re-quote finding bodies the voice pass already gated, and a whitelist
keeps a newly added section out until someone decides it belongs.

Excluded lines are blanked rather than dropped, so reported line numbers point
at the review file itself.

Output (stdout):

    {"file": "...", "count": 2, "annotated": true, "error": null,
     "warnings": [{"line": 34, "category": "hype", "message": "...",
                   "text": "..."}]}

Fails open: any internal failure prints a zero-count result with `error` set and
exits 0, and --annotate leaves the file untouched on that path. Nothing here
blocks a review.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "helpers"))

from lint_loader import load_linter  # noqa: E402

NOTES_HEADING = "## Lint notes"
TEXT_EXCERPT_CHARS = 160
DEFAULT_PER_CATEGORY_LIMIT = 5

ANY_HEADING = re.compile(r"^ {0,3}#{1,6}\s")
H1 = re.compile(r"^ {0,3}#\s")
H2 = re.compile(r"^ {0,3}##\s")
NARRATIVE_SECTION = re.compile(r"^ {0,3}##\s+(?:Overview|.+\sReview)\s*$")
NOTES_SECTION = re.compile(r"^ {0,3}##\s+Lint notes\s*$")
FINDING_START = re.compile(
    r"^\s*(?:\*\*)?`?(?:blocking|suggestion|question|nit)`?(?:\*\*)?\s*:",
    re.I,
)

PREAMBLE = (
    "Voice-lint warnings on this review's narrative prose (the Overview and the "
    "per-agent summaries). Finding bodies are checked separately during the voice "
    "pass. Nothing below was changed automatically."
)


def empty_result(path: str, error: str | None = None) -> dict:
    return {
        "file": path,
        "count": 0,
        "annotated": False,
        "warnings": [],
        "error": error,
    }


def mask_non_narrative(linter, lines: list[str]) -> list[str]:
    """Blank every line that is not narrative prose, preserving line count."""
    masked = [""] * len(lines)
    in_section = False
    in_finding = False
    fence = ""
    paragraph_start = True

    for index, line in enumerate(lines):
        marker = linter.FENCE.match(line)
        token = marker.group(1) if marker else ""

        if fence:
            if marker and token.startswith(fence) and not line[marker.end():].strip():
                fence = ""
            if in_section and not in_finding:
                masked[index] = line
            paragraph_start = False
            continue

        if token:
            fence = token
            if in_section and not in_finding:
                masked[index] = line
            paragraph_start = False
            continue

        if ANY_HEADING.match(line):
            # A heading always ends a finding block. H2 decides the section; an
            # H1 leaves every section; H3 and deeper nest inside the current one.
            in_finding = False
            if H2.match(line):
                in_section = bool(NARRATIVE_SECTION.match(line))
            elif H1.match(line):
                in_section = False
            paragraph_start = True
            continue

        if not line.strip():
            paragraph_start = True
            continue

        if linter.HR.match(line):
            in_finding = False
            paragraph_start = True
            continue

        if paragraph_start and FINDING_START.match(line):
            in_finding = True

        if in_section and not in_finding:
            masked[index] = line
        paragraph_start = False

    return masked


def collect(linter, text: str, limit: int) -> tuple[list[dict], dict[str, int]]:
    masked = mask_non_narrative(linter, text.splitlines())
    warnings = linter.lint("\n".join(masked))
    warnings.sort(key=lambda item: (item["line"], item["category"]))
    kept, suppressed = linter.cap_warnings(warnings, limit)
    trimmed = [
        {
            "line": item["line"],
            "category": item["category"],
            "message": item["message"],
            "text": item["text"][:TEXT_EXCERPT_CHARS],
        }
        for item in kept
    ]
    return trimmed, suppressed


def strip_notes_section(lines: list[str]) -> list[str]:
    """Drop an existing Lint notes section so re-running never stacks them."""
    start = next(
        (index for index, line in enumerate(lines) if NOTES_SECTION.match(line)),
        None,
    )
    if start is None:
        return lines
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if H2.match(lines[index]) or H1.match(lines[index])
        ),
        len(lines),
    )
    trimmed = lines[:start] + lines[end:]
    while trimmed and not trimmed[-1].strip():
        trimmed.pop()
    return trimmed


def render_notes(warnings: list[dict], suppressed: dict[str, int]) -> list[str]:
    lines = [NOTES_HEADING, "", PREAMBLE, ""]
    for item in warnings:
        lines.append(f"> line {item['line']}, {item['category']}: {item['text']}")
    for category, count in sorted(suppressed.items()):
        lines.append(f"> {count} further {category} warning(s) not listed.")
    return lines


def annotate(path: Path, warnings: list[dict], suppressed: dict[str, int]) -> bool:
    lines = strip_notes_section(path.read_text(encoding="utf-8").splitlines())
    if warnings or suppressed:
        lines.extend([""] + render_notes(warnings, suppressed))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return bool(warnings or suppressed)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", help="Composed review markdown file to lint")
    parser.add_argument(
        "--annotate",
        action="store_true",
        help="Write the warnings into the file as a Lint notes section, replacing "
        "any section a previous run left",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_PER_CATEGORY_LIMIT,
        metavar="<n>",
        help=f"Keep at most n warnings per category (default: "
        f"{DEFAULT_PER_CATEGORY_LIMIT}; 0 keeps them all)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        path = Path(args.file)
        linter = load_linter()
        warnings, suppressed = collect(
            linter, path.read_text(encoding="utf-8"), args.limit
        )
        annotated = annotate(path, warnings, suppressed) if args.annotate else False
    except Exception as error:  # noqa: BLE001 - fail open on anything
        print(json.dumps(empty_result(args.file, f"{type(error).__name__}: {error}")))
        return 0

    print(
        json.dumps(
            {
                "file": str(path),
                "count": len(warnings) + sum(suppressed.values()),
                "annotated": annotated,
                "warnings": warnings,
                "error": None,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
