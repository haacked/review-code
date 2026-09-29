#!/usr/bin/env python3
"""Check handwritten editor fixtures through the current finding safeguards offline."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    spec = importlib.util.spec_from_file_location(
        name.replace("-", "_"), ROOT / "skills/review-code/scripts" / f"{name}.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


voice = load_script("gate-voice-preservation")
contract = load_script("finding-comment-contract")


def editor_publication(
    quality: dict,
    candidates: list,
    decisions: list,
    *,
    recover_identical_body: bool = False,
    independent_verdicts: list | None = None,
) -> dict:
    originals = {item["id"]: item for item in quality["findings"]}
    candidates = [
        item
        for item in candidates
        if not isinstance(item, dict) or item.get("id") != "overview"
    ]
    indexed = voice.index_entries(candidates, set(originals), "candidate", [])
    checked = []
    for candidate in candidates:
        if isinstance(candidate, dict) and voice.valid_id(candidate.get("id")):
            original = originals.get(candidate["id"])
            if (
                original
                and candidate.get("unchanged") is True
                and any(
                    candidate.get(field) != original.get(field)
                    for field in voice.FIELDS
                )
            ):
                candidate = {**candidate, "error": "unchanged response changed a field"}
        checked.append(candidate)
    merged = voice.merge(quality, checked, decisions)
    reverted = {item["id"] for item in merged["voice_preservation"]["reverted"]}
    if recover_identical_body:
        for item in merged["findings"]:
            entries = indexed.get(item["id"], [])
            if (
                len(entries) == 1
                and voice.candidate_valid(entries[0])
                and entries[0]["description"] == item["description"]
            ):
                reverted.discard(item["id"])
    # A verdict about a rejected edit cannot approve a different restored body.
    verdicts = [
        item
        for item in (
            candidates if independent_verdicts is None else independent_verdicts
        )
        if isinstance(item, dict)
        and contract.valid_identifier(item.get("id"))
        and item["id"] not in reverted
    ]
    return contract.publish(contract.gate(merged, verdicts, final=True))


def replay(data: dict) -> dict:
    if not isinstance(data, dict) or not isinstance(data.get("cases"), list):
        raise TypeError("fixtures must contain a cases array")
    if not data["cases"]:
        raise ValueError("fixtures must contain at least one case")
    rows = []
    identifiers = set()
    for case in data["cases"]:
        if not isinstance(case, dict):
            raise TypeError("each case must be an object")
        identifier = case.get("id")
        if not isinstance(identifier, str) or not identifier.strip():
            raise ValueError("each case needs a nonempty string id")
        if identifier in identifiers:
            raise ValueError("case ids must be unique")
        identifiers.add(identifier)
        for field in ("findings", "candidates", "preservation"):
            if not isinstance(case.get(field), list):
                raise TypeError(f"{field} must be an array")
        recovery = case.get("recover_identical_body", False)
        if type(recovery) is not bool:
            raise TypeError("recover_identical_body must be a boolean")
        if "independent_verdicts" in case and not isinstance(
            case["independent_verdicts"], list
        ):
            raise TypeError("independent_verdicts must be an array")
        expected = case.get("expected")
        if not isinstance(expected, dict):
            raise TypeError("expected must be an object")
        for field in ("published_ids", "withheld_ids"):
            ids = expected.get(field)
            if not isinstance(ids, list) or any(
                not contract.valid_identifier(value) for value in ids
            ):
                raise TypeError(f"expected {field} must be an array of valid ids")
            if len(ids) != len(set(ids)):
                raise ValueError(f"expected {field} must contain unique ids")
        publication = editor_publication(
            contract.compose(case["findings"]),
            case["candidates"],
            case["preservation"],
            recover_identical_body=recovery,
            independent_verdicts=case.get("independent_verdicts"),
        )
        published = [item["id"] for item in publication["findings"]]
        withheld = [item["id"] for item in publication["withheld"]]
        rows.append(
            {
                "id": identifier,
                "published_ids": published,
                "withheld_ids": withheld,
                "matches_expected": set(published) == set(expected["published_ids"])
                and set(withheld) == set(expected["withheld_ids"]),
            }
        )
    return {"cases": rows, "all_expected": all(row["matches_expected"] for row in rows)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fixtures", type=Path, default=ROOT / "evals/editor-pass/fixtures.json"
    )
    args = parser.parse_args()
    try:
        result = replay(json.loads(args.fixtures.read_text()))
    except (OSError, KeyError, TypeError, ValueError) as error:
        print(f"Invalid fixtures: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0 if result["all_expected"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
