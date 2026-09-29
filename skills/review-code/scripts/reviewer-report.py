#!/usr/bin/env python3
"""Save reviewer evidence separately from the findings used for synthesis."""

import argparse
import html
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True

from helpers.reviewer_budget import validate_budget


def render_limitations(name, coverage, budget):
    if not coverage["gaps"]:
        return ""
    heading = f"### {name}\n\n"
    if budget and budget["status"] == "limited":
        heading += (
            "Review incomplete: soft work budget reached "
            f"({budget['tool_calls']}/{budget['limits']['tool_calls']} tool calls, "
            f"{budget['searches']}/{budget['limits']['searches']} searches).\n\n"
        )
    else:
        heading += "Review incomplete: coverage gaps remain.\n\n"
    gaps = []
    for gap in coverage["gaps"]:
        text = html.escape(" ".join(gap.splitlines()), quote=False)
        text = re.sub(r"([\\`*_{}\[\]#|])", r"\\\1", text)
        gaps.append(f"- {text}\n")
    return heading + "".join(gaps) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--require-budget", action="store_true")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.name):
            raise ValueError("name must be a file name without directory components")
        report = json.loads(args.input.read_text())
        if not isinstance(report, dict):
            raise TypeError("report must be a JSON object")
        investigation = report.get("investigation")
        findings = report.get("findings")
        coverage = report.get("coverage")
        if not isinstance(investigation, str) or not investigation.strip():
            raise ValueError("investigation must be a nonempty string")
        if not isinstance(findings, str):
            raise TypeError("findings must be a string, empty when no findings remain")
        if not isinstance(coverage, dict):
            raise TypeError("coverage must be an object")
        for field in ("files_read", "gaps"):
            values = coverage.get(field)
            if not isinstance(values, list) or any(
                not isinstance(value, str) or not value.strip() for value in values
            ):
                raise ValueError(
                    f"coverage.{field} must be an array of nonempty strings"
                )
        if "BRIEFING_UNAVAILABLE" in (investigation.strip(), findings.strip()):
            raise ValueError("reviewer could not read its briefing")
        budget = validate_budget(coverage, required=args.require_budget)

        artifacts = {
            "investigation_path": (
                args.output_dir / "investigations" / f"{args.name}.md",
                investigation,
            ),
            "findings_path": (
                args.output_dir / "findings" / f"{args.name}.md",
                findings,
            ),
            "coverage_path": (
                args.output_dir / "coverage" / f"{args.name}.json",
                json.dumps(coverage, indent=2) + "\n",
            ),
            "limitations_path": (
                args.output_dir / "limitations" / f"{args.name}.md",
                render_limitations(args.name, coverage, budget),
            ),
        }
        for path, body in artifacts.values():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        paths = {key: path for key, (path, _) in artifacts.items()}
        print(
            json.dumps(
                {
                    "report_name": args.name,
                    **{key: str(path) for key, path in paths.items()},
                    **({"budget": budget} if budget is not None else {}),
                    "files_read_count": len(coverage["files_read"]),
                    "gaps": coverage["gaps"],
                    "finding_bytes": len(findings.encode()),
                }
            )
        )
    except (OSError, TypeError, ValueError) as error:
        parser.exit(1, f"reviewer report: {error}\n")


if __name__ == "__main__":
    main()
