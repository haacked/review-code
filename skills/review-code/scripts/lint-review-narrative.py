#!/usr/bin/env python3
"""Lint the narrative prose in a composed review and record what it finds.

The voice agent rewrites finding bodies and never sees the Overview or the
per-agent summaries, so that prose is the one place in a review nothing checks.
This script lints exactly that prose and, with --annotate, writes the warnings
into the review as a "Lint notes" section.

What counts as narrative is a whitelist: the body of `## Overview`, `## Fix
Summary`, and every `## <Something> Review` section, minus the finding blocks
inside them. A finding block starts at a paragraph or heading opening with a
severity token (`blocking`, `suggestion`, `question`, `nit`, separated by a
colon or an em dash) and runs to the next thematic break or heading. Suggested
Comments, tables, and the metadata header are skipped: the first re-quotes
finding bodies the voice pass already gated, and a whitelist keeps a newly added
section out until someone decides it belongs. Fix Summary is the fix pass's own
prose, so it is linted.

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
import os
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
DEFAULT_PER_CATEGORY_LIMIT = 5

# A heading at level 1 or 2: the level that opens or closes a section. H3 and
# deeper nest inside whatever section is current.
TOP_HEADING = re.compile(r"^ {0,3}#{1,2}\s")
# H3 as well as H2: some reviews nest the per-agent summaries under a
# non-narrative H2, and an H2-only whitelist would report those as clean.
# "Overview" and "<Something> Review" are the composer's per-agent sections;
# "Fix Summary" is written by the fix pass and, unlike Suggested Comments, is
# the composer's own prose rather than finding bodies the voice pass gated.
NARRATIVE_SECTION = re.compile(
    r"^ {0,3}#{2,3}\s+(?:Overview|Fix Summary|.+\sReview)\s*$"
)
NOTES_SECTION = re.compile(r"^ {0,3}##\s+Lint notes\s*$")


PREAMBLE = (
    "Voice-lint warnings on this review's narrative prose (the Overview and the "
    "per-agent summaries). Finding bodies are checked separately during the voice "
    "pass. Nothing below was changed automatically."
)


def result(path, *, count=0, annotated=False, warnings=(), error=None) -> dict:
    return {
        "file": str(path),
        "count": count,
        "annotated": annotated,
        "warnings": list(warnings),
        "error": error,
    }


def outside_fences(linter, lines: list[str]):
    """Yield (index, line) for every line outside a fenced code block."""
    fence = ""
    for index, line in enumerate(lines):
        marker = linter.FENCE.match(line)
        token = marker.group(1) if marker else ""
        if fence:
            if marker and token.startswith(fence) and not line[marker.end() :].strip():
                fence = ""
            continue
        if token:
            fence = token
            continue
        yield index, line


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
            if marker and token.startswith(fence) and not line[marker.end() :].strip():
                fence = ""
            paragraph_start = False
        elif token:
            fence = token
            paragraph_start = False
        elif linter.HEADING.match(line):
            # A heading always ends a finding block. An H2 or H3 naming a
            # narrative section enters one; any other H1 or H2 leaves.
            in_finding = False
            if NARRATIVE_SECTION.match(line):
                in_section = True
            elif TOP_HEADING.match(line):
                in_section = False
            elif linter.SEVERITY_PREFIX.match(linter.HEADING.sub("", line)):
                # A heading can open a finding: `### `blocking`: title`.
                in_finding = True
            paragraph_start = True
        elif not line.strip():
            paragraph_start = True
        elif linter.HR.match(line):
            in_finding = False
            paragraph_start = True
        else:
            if paragraph_start and linter.SEVERITY_PREFIX.match(line):
                in_finding = True
            paragraph_start = False

        # Headings, blank lines, thematic breaks, and `Location:` trailers reach
        # this in their own right; `prose_lines` skips all four, so passing them
        # through changes nothing that gets reported.
        if in_section and not in_finding:
            masked[index] = line

    return masked


def collect(linter, lines: list[str], limit: int) -> tuple[list[dict], dict[str, int]]:
    masked = mask_non_narrative(linter, lines)
    warnings = linter.lint("\n".join(masked))
    warnings.sort(key=lambda item: (item["line"], item["category"]))
    kept, suppressed = linter.cap_warnings(warnings, limit)
    return [linter.trim_warning(item) for item in kept], suppressed


def find_notes_heading(linter, lines: list[str]) -> int | None:
    """Locate a real Lint notes heading, ignoring one quoted inside a fence.

    A finding body can quote a markdown file that contains this heading. Without
    the fence walk, that quoted line reads as a section opener and everything
    from it to the next heading is cut from the saved review.
    """
    return next(
        (
            index
            for index, line in outside_fences(linter, lines)
            if NOTES_SECTION.match(line)
        ),
        None,
    )


def strip_notes_section(linter, lines: list[str], start: int | None) -> list[str]:
    """Drop an existing Lint notes section so re-running never stacks them.

    The section ends at the next H1 or H2, or at a thematic break, whichever
    comes first. Stopping at the break matters on the delta path, where the
    carry-forward merge writes one between the previous review and the new one.
    """
    if start is None:
        return lines
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if TOP_HEADING.match(lines[index]) or linter.HR.match(lines[index])
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
    linter,
    path: Path,
    lines: list[str],
    warnings: list[dict],
    suppressed: dict[str, int],
) -> bool:
    start = find_notes_heading(linter, lines)
    # Nothing to say and nothing stale to remove: leave the file alone rather
    # than rewriting it, which would normalize its line endings and its
    # trailing newline for no reason.
    if not warnings and not suppressed and start is None:
        return False
    lines = strip_notes_section(linter, lines, start)
    if warnings or suppressed:
        lines.extend([""] + render_notes(warnings, suppressed))
    # Replace atomically: write_text truncates first, so a write that fails
    # part-way would leave the review a partial file, and the fail-open handler
    # would report that as a clean skip.
    tmp = path.with_name(f".{path.name}.lint-notes")
    try:
        tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)
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
        lines = path.read_text(encoding="utf-8").splitlines()
        warnings, suppressed = collect(linter, lines, args.limit)
        annotated = (
            annotate(linter, path, lines, warnings, suppressed)
            if args.annotate
            else False
        )
    except Exception as error:  # noqa: BLE001 - fail open on anything
        print(json.dumps(result(args.file, error=f"{type(error).__name__}: {error}")))
        return 0

    print(
        json.dumps(
            result(
                path,
                count=len(warnings) + sum(suppressed.values()),
                annotated=annotated,
                warnings=warnings,
            )
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
