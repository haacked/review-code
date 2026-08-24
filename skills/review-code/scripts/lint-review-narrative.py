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

# Set before the helper import and before the loader's exec_module: both are
# what would write bytecode into the installed skill tree, where __pycache__ is
# not dot-prefixed and so lands in the counted part of the skill.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "helpers"))

from lint_loader import load_linter  # noqa: E402

NOTES_HEADING = "## Lint notes"
TEXT_EXCERPT_CHARS = 160
DEFAULT_PER_CATEGORY_LIMIT = 5

ANY_HEADING = re.compile(r"^ {0,3}#{1,6}\s")
H1 = re.compile(r"^ {0,3}#\s")
H2 = re.compile(r"^ {0,3}##\s")
# H3 as well as H2: some reviews nest the per-agent summaries under a
# non-narrative H2, and an H3-only whitelist would report those as clean.
NARRATIVE_SECTION = re.compile(r"^ {0,3}#{2,3}\s+(?:Overview|.+\sReview)\s*$")
NOTES_SECTION = re.compile(r"^ {0,3}##\s+Lint notes\s*$")
# Findings open with a severity token separated by a colon or an em/en dash.
# The ASCII hyphen is deliberately excluded: it would swallow a sentence
# opening "Nit-picking aside".
FINDING_START = re.compile(
    r"^\s*(?:\*\*)?`?(?:blocking|suggestion|question|nit)`?(?:\*\*)?\s*(?::|\s*[—–])",
    re.I,
)
# The trailer the agents write under a fenced finding body
# (`Location: path:line | Confidence: NN%`). The linter's own LABEL_LINE only
# matches a bare `Location:` with nothing after it, so without this the trailer
# reads as narrative and its em dash reports on every finding.
FINDING_TRAILER = re.compile(r"^\s*(?:\*\*)?Location(?:\*\*)?\s*:", re.I)

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
        # Set by branches whose line must be blanked even inside a narrative
        # section, because `prose_lines` would otherwise read it as prose.
        structural = False

        if fence:
            if marker and token.startswith(fence) and not line[marker.end():].strip():
                fence = ""
            paragraph_start = False
        elif token:
            fence = token
            paragraph_start = False
        elif ANY_HEADING.match(line):
            # A heading always ends a finding block. An H2 or H3 naming a
            # narrative section enters one; any other H2 or an H1 leaves.
            in_finding = False
            if NARRATIVE_SECTION.match(line):
                in_section = True
            elif H2.match(line) or H1.match(line):
                in_section = False
            paragraph_start = True
        elif not line.strip():
            paragraph_start = True
        elif linter.HR.match(line):
            in_finding = False
            paragraph_start = True
        elif FINDING_TRAILER.match(line):
            structural = True
            paragraph_start = False
        else:
            if paragraph_start and FINDING_START.match(line):
                in_finding = True
            paragraph_start = False

        # Headings, blank lines, and thematic breaks reach this in their own
        # right; `prose_lines` skips all three, so passing them through changes
        # nothing that gets reported. The trailer is not one of those, so it
        # sets `structural` to opt out.
        if in_section and not in_finding and not structural:
            masked[index] = line

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


def find_notes_heading(linter, lines: list[str]) -> int | None:
    """Locate a real Lint notes heading, ignoring one quoted inside a fence.

    A finding body can quote a markdown file that contains this heading. Without
    the fence walk, that quoted line reads as a section opener and everything
    from it to the next heading is cut from the saved review.
    """
    fence = ""
    for index, line in enumerate(lines):
        marker = linter.FENCE.match(line)
        token = marker.group(1) if marker else ""
        if fence:
            if marker and token.startswith(fence) and not line[marker.end():].strip():
                fence = ""
            continue
        if token:
            fence = token
            continue
        if NOTES_SECTION.match(line):
            return index
    return None


def strip_notes_section(linter, lines: list[str]) -> list[str]:
    """Drop an existing Lint notes section so re-running never stacks them."""
    start = find_notes_heading(linter, lines)
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


def annotate(
    linter, path: Path, warnings: list[dict], suppressed: dict[str, int]
) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines()
    has_notes = find_notes_heading(linter, lines) is not None
    # Nothing to say and nothing stale to remove: leave the file alone rather
    # than rewriting it, which would normalize its line endings and its
    # trailing newline for no reason.
    if not warnings and not suppressed and not has_notes:
        return False
    lines = strip_notes_section(linter, lines)
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
        annotated = (
            annotate(linter, path, warnings, suppressed) if args.annotate else False
        )
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
