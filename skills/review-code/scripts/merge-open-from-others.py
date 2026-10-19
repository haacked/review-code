#!/usr/bin/env python3
"""Merge every reviewer's open_from_others entries into one list for the review.

Each reviewer that read the same PR comment lists its problem, so one problem
arrives once per reviewer. Entries that share a link, a location, and a
commenter become one entry that keeps each reviewer's own statement of the
problem and its assessment. The merged list goes to open-from-others.json, and
stdout carries only its size, because the compose step is the first to need
the list.
"""

import argparse
import json
from pathlib import Path
import re

KEY_FIELDS = ("link", "location", "raised_by")
ASSESSMENT_FIELDS = ("problem", "assessment", "severity", "why_not_reraised")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", required=True, type=Path)
    args = parser.parse_args()
    groups = {}
    try:
        for path in sorted((args.artifacts_dir / "open-from-others").glob("*.json")):
            reviewer = re.sub(r"^chunk-\d+-", "", path.stem)
            for entry in json.loads(path.read_text()):
                key = tuple(entry[field] for field in KEY_FIELDS)
                group = groups.setdefault(
                    key, {**dict(zip(KEY_FIELDS, key)), "assessments": []}
                )
                group["assessments"].append(
                    {
                        "reviewer": reviewer,
                        **{field: entry[field] for field in ASSESSMENT_FIELDS},
                    }
                )
        (args.artifacts_dir / "open-from-others.json").write_text(
            json.dumps(list(groups.values()), indent=2) + "\n"
        )
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"merge open-from-others: {error}\n")
    print(json.dumps({"count": len(groups)}))


if __name__ == "__main__":
    main()
