#!/usr/bin/env python3
"""Save reviewer evidence separately from the findings used for synthesis."""

import argparse
import json
from pathlib import Path
import re

OPEN_FIELDS = ("location", "raised_by", "link", "problem", "why_not_reraised")
ASSESSMENTS = ("valid", "invalid", "unsure")
SEVERITIES = ("blocking", "suggestion", "question", "nit")


def validate_open_from_others(entries):
    if not isinstance(entries, list):
        raise ValueError(
            "open_from_others must be an array, empty when nothing is open"
        )
    for index, entry in enumerate(entries):
        prefix = f"open_from_others[{index}]"
        if not isinstance(entry, dict):
            raise ValueError(f"{prefix} must be an object")
        for field in OPEN_FIELDS:
            value = entry.get(field)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{prefix}.{field} must be a nonempty string")
        if not re.match(r"https?://", entry["link"]):
            raise ValueError(f"{prefix}.link must be an http or https URL")
        if entry.get("assessment") not in ASSESSMENTS:
            raise ValueError(
                f"{prefix}.assessment must be one of {', '.join(ASSESSMENTS)}"
            )
        if entry.get("severity") not in SEVERITIES:
            raise ValueError(
                f"{prefix}.severity must be one of {', '.join(SEVERITIES)}"
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--name", required=True)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.name):
            raise ValueError("name must be a file name without directory components")
        report = json.loads(args.input.read_text())
        if not isinstance(report, dict):
            raise ValueError("report must be a JSON object")
        investigation = report.get("investigation")
        findings = report.get("findings")
        coverage = report.get("coverage")
        if not isinstance(investigation, str) or not investigation.strip():
            raise ValueError("investigation must be a nonempty string")
        if not isinstance(findings, str):
            raise ValueError("findings must be a string, empty when no findings remain")
        if not isinstance(coverage, dict):
            raise ValueError("coverage must be an object")
        for field in ("files_read", "gaps"):
            values = coverage.get(field)
            if not isinstance(values, list) or any(
                not isinstance(value, str) or not value.strip() for value in values
            ):
                raise ValueError(
                    f"coverage.{field} must be an array of nonempty strings"
                )
        open_from_others = report.get("open_from_others")
        validate_open_from_others(open_from_others)
        if "BRIEFING_UNAVAILABLE" in (investigation.strip(), findings.strip()):
            raise ValueError("reviewer could not read its briefing")

        paths = {
            "investigation_path": args.output_dir
            / "investigations"
            / f"{args.name}.md",
            "findings_path": args.output_dir / "findings" / f"{args.name}.md",
            "coverage_path": args.output_dir / "coverage" / f"{args.name}.json",
        }
        # Synthesis merges the open entries by directory. Stdout omits their path.
        open_from_others_path = (
            args.output_dir / "open-from-others" / f"{args.name}.json"
        )
        content = (
            investigation,
            findings,
            json.dumps(coverage, indent=2) + "\n",
            json.dumps(open_from_others, indent=2) + "\n",
        )
        for path, body in zip((*paths.values(), open_from_others_path), content):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        print(
            json.dumps(
                {
                    **{key: str(path) for key, path in paths.items()},
                    "files_read_count": len(coverage["files_read"]),
                    "gaps": coverage["gaps"],
                    "finding_bytes": len(findings.encode()),
                    "open_from_others_count": len(open_from_others),
                }
            )
        )
    except (OSError, ValueError) as error:
        parser.exit(1, f"reviewer report: {error}\n")


if __name__ == "__main__":
    main()
