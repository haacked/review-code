#!/usr/bin/env python3
"""Lint the bodies the voice pass produced and report which ones still read wrong.

Reads a JSON array of accepted voice-pass rewrites on stdin and runs
lint-comment-voice.py over each `description` and `proposed_fix`. Prints one
JSON object naming the findings that still carry warnings, so the caller can
bounce them back to the voice agent once and revert the ones that come back
dirty.

This script decides nothing about the review. It reports; the caller reverts.

Input (stdin), one object per accepted rewrite:

    [{"id": 1, "description": "...", "proposed_fix": "... or null"}]

Output (stdout):

    {"checked": 9, "clean": 7, "warned": 2, "warned_ids": [3, 7],
     "findings": [{"id": 3, "warnings": [
        {"field": "description", "line": 1, "category": "pinning",
         "message": "...", "text": "..."}]}],
     "error": null}

Fails open: any internal failure prints a zero-count result with `error` set
and exits 0, so a bad input or a broken rule can never block a review.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Set before the helper import and before the loader's exec_module: both are
# what would write bytecode into the installed skill tree, where __pycache__ is
# not dot-prefixed and so lands in the counted part of the skill.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "helpers"))

from lint_loader import load_linter  # noqa: E402

# Warning text is echoed back to the voice agent in the retry prompt. A body
# that trips the same rule on ten lines does not need ten examples to be fixed,
# and an uncapped payload is paid for at output-token prices.
DEFAULT_PER_FINDING_LIMIT = 6
TEXT_EXCERPT_CHARS = 160

# The fields a rewrite can carry. `proposed_fix` is often null.
LINTED_FIELDS = ("description", "proposed_fix")


def empty_result(error: str | None = None) -> dict:
    return {
        "checked": 0,
        "clean": 0,
        "warned": 0,
        "warned_ids": [],
        "findings": [],
        "error": error,
    }


def lint_body(linter, text: str, field: str) -> list[dict]:
    """Lint one field and tag each warning with the field it came from."""
    return [
        {
            "field": field,
            "line": item["line"],
            "category": item["category"],
            "message": item["message"],
            "text": item["text"][:TEXT_EXCERPT_CHARS],
        }
        for item in linter.lint(text)
    ]


def gate(linter, items: list, limit: int) -> dict:
    result = empty_result()
    findings = []

    for item in items:
        if not isinstance(item, dict):
            continue
        result["checked"] += 1
        warnings: list[dict] = []
        for field in LINTED_FIELDS:
            value = item.get(field)
            if isinstance(value, str) and value.strip():
                warnings.extend(lint_body(linter, value, field))

        if not warnings:
            result["clean"] += 1
            continue

        result["warned"] += 1
        # Indexing, not .get: an entry with no id would put null into
        # warned_ids and send the caller bouncing an id no finding has.
        # Raising here lands on the documented fail-open result instead.
        identifier = item["id"]
        result["warned_ids"].append(identifier)
        if limit > 0 and len(warnings) > limit:
            suppressed = len(warnings) - limit
            warnings = warnings[:limit]
            warnings.append(
                {
                    "field": "",
                    "line": 0,
                    "category": "note",
                    "message": f"{suppressed} further warning(s) not listed.",
                    "text": "",
                }
            )
        findings.append({"id": identifier, "warnings": warnings})

    result["findings"] = findings
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "file",
        nargs="?",
        default="-",
        help="JSON file of accepted rewrites; reads stdin when omitted or '-'",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_PER_FINDING_LIMIT,
        metavar="<n>",
        help=f"Keep at most n warnings per finding (default: {DEFAULT_PER_FINDING_LIMIT}; "
        "0 keeps them all)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        raw = (
            sys.stdin.read()
            if args.file == "-"
            else Path(args.file).read_text(encoding="utf-8")
        )
        items = json.loads(raw)
        if not isinstance(items, list):
            raise ValueError("input must be a JSON array of rewrites")
        result = gate(load_linter(), items, args.limit)
    except Exception as error:  # noqa: BLE001 - fail open on anything
        print(json.dumps(empty_result(f"{type(error).__name__}: {error}")))
        return 0

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
