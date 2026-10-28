#!/usr/bin/env python3
"""Lint finding bodies before the final gate and report which ones read wrong.

Reads findings from a file, or from stdin when the path is '-', and runs
lint-comment-voice.py over each `description` and `proposed_fix`. The input is
a JSON array of findings or an object whose `findings` holds one, such as the
finding-quality state. The pipeline passes a path: finding bodies quote the
diff, so inlining them into a command is a delimiter hazard. Prints one JSON
object naming the findings that carry warnings. With --repair-input, it also
writes the findings the caller sends to the composer once, with the warnings as
repair reasons.

This script decides nothing about the review. It reports; the caller repairs.

Input, one object per finding. The lint ignores any other fields, and the
repair input keeps them:

    [{"id": 1, "comment_style": "concise", "description": "...",
      "proposed_fix": "... or null"}]

A `concise` description, the default when `comment_style` is absent, also gets
a `concise_length` warning when its prose has more than two sentences or 40
words.

Output (stdout):

    {"checked": 9, "clean": 7, "warned": 2, "repair_ids": [3],
     "findings": [{"id": 3, "warnings": [
        {"field": "description", "line": 1, "category": "pinning",
         "message": "...", "text": "..."}], "reasons": ["..."],
        "suppressed": 2}],
     "error": null}

`suppressed` appears only when --limit dropped warnings from that finding.
`reasons` holds one sentence per kept warning, in the form the composer reads.
`repair_ids` lists the warned ids with a warning other than `concise_length`.
--repair-input writes those findings as they came in, with `reasons` set to
their lint reasons and without the preflight's `unresolved` phrases, which
composition already addressed.

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

# Every warning on a finding is echoed back to the composer in the repair
# input, so this caps the whole list per finding rather than per category: what
# needs bounding is the total payload, which a per-category cap would not bound.
DEFAULT_PER_FINDING_LIMIT = 6

# The body fields of a finding. `proposed_fix` is often null.
LINTED_FIELDS = ("description", "proposed_fix")


def result(*, checked: int = 0, findings=(), error=None) -> dict:
    """Build the one result shape, so the error path cannot drift from the rest."""
    findings = list(findings)
    return {
        "checked": checked,
        "clean": checked - len(findings),
        "warned": len(findings),
        # A body that is only too long skips the repair, because the final
        # comprehension gate also judges length and asks for a trim itself.
        "repair_ids": [
            finding["id"]
            for finding in findings
            if any(w["category"] != "concise_length" for w in finding["warnings"])
        ],
        "findings": findings,
        "error": error,
    }


def gate(linter, items: list, limit: int) -> dict:
    checked = 0
    findings: list[dict] = []

    for item in items:
        if not isinstance(item, dict):
            continue
        checked += 1
        warnings: list[dict] = []
        for field in LINTED_FIELDS:
            value = item.get(field)
            if isinstance(value, str) and value.strip():
                warnings.extend(
                    linter.trim_warning(w, field=field) for w in linter.lint(value)
                )

        # Only `description` is posted, so only it has a length limit.
        description = item.get("description")
        if (
            item.get("comment_style", "concise") == "concise"
            and isinstance(description, str)
            and (length_warning := linter.concise_length_warning(description))
        ):
            warnings.append(linter.trim_warning(length_warning, field="description"))

        if not warnings:
            continue

        # Indexing, not .get: a warned entry with no id would put null into
        # repair_ids. No finding has that id. Raising here lands on the
        # documented fail-open result instead.
        finding = {"id": item["id"], "warnings": warnings}
        if limit > 0 and len(warnings) > limit:
            finding["warnings"] = warnings[:limit]
            finding["suppressed"] = len(warnings) - limit
        finding["reasons"] = [
            f"{w['message']} In {w['field']}: {w['text']}" for w in finding["warnings"]
        ]
        findings.append(finding)

    return result(checked=checked, findings=findings)


def repair_input(items: list, gated: dict) -> list[dict]:
    reasons = {finding["id"]: finding["reasons"] for finding in gated["findings"]}
    return [
        {
            **{key: value for key, value in item.items() if key != "unresolved"},
            "reasons": reasons[item["id"]],
        }
        for item in items
        if isinstance(item, dict) and item.get("id") in gated["repair_ids"]
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "file",
        nargs="?",
        default="-",
        help="JSON file of findings; reads stdin when omitted or '-'",
    )
    parser.add_argument(
        "--repair-input",
        type=Path,
        metavar="<path>",
        help="Also write the findings in repair_ids to this file, each with its "
        "lint reasons",
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
        data = json.loads(raw)
        items = data.get("findings") if isinstance(data, dict) else data
        if not isinstance(items, list):
            raise ValueError(
                "input must be a JSON array of findings or an object with one"
            )
        gated = gate(load_linter(), items, args.limit)
        if args.repair_input:
            args.repair_input.write_text(
                json.dumps(repair_input(items, gated)), encoding="utf-8"
            )
    except Exception as error:  # noqa: BLE001 - fail open on anything
        print(json.dumps(result(error=f"{type(error).__name__}: {error}")))
        return 0

    print(json.dumps(gated))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
