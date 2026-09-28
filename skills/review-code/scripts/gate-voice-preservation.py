#!/usr/bin/env python3
"""Merge voice edits only after structural checks and an independent meaning check.

The orchestrator supplies semantic verdicts. This script cannot judge meaning.
Response or verdict failures restore the corresponding pre-voice findings.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "helpers"))

from markdown_fences import walk_fences

FIELDS = ("description", "proposed_fix")
SEVERITY = r"(?:blocking|suggestion|question|nit)"
PREFIX = re.compile(rf"^(?:`{SEVERITY}`|\*\*{SEVERITY}\*\*|{SEVERITY}):", re.IGNORECASE)
INLINE_CODE = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", re.DOTALL)


def read_array(path: str, *, fenced: bool = False) -> list:
    raw = Path(path).read_text(encoding="utf-8").strip()
    if fenced:
        match = re.fullmatch(r"````json\s*\n(.*)\n````", raw, re.DOTALL)
        if match:
            raw = match[1]
    value = json.loads(raw)
    if not isinstance(value, list):
        raise TypeError("expected a JSON array")
    return value


def valid_id(value) -> bool:
    return type(value) is int or isinstance(value, str) and bool(value.strip())


def index_entries(entries: list, expected: set, label: str, anomalies: list) -> dict:
    indexed: dict = {}
    for entry in entries:
        if not isinstance(entry, dict) or not valid_id(entry.get("id")):
            anomalies.append(f"{label}: entry has no valid id")
            continue
        identifier = entry["id"]
        if identifier not in expected:
            anomalies.append(f"{label}: unknown id {identifier!r}")
            continue
        indexed.setdefault(identifier, []).append(entry)
    return indexed


def markdown_parts(body: str) -> tuple[list[str], Counter[str]]:
    blocks, prose, current = [], [], []
    for _, line, kind in walk_fences(body.splitlines(keepends=True)):
        if kind == "prose":
            prose.append(line)
        else:
            current.append(line)
            if kind == "close":
                blocks.append("".join(current))
                current = []
                prose.append("\n")
    if current:
        blocks.append("".join(current))
    tokens = Counter(match[0] for match in INLINE_CODE.finditer("".join(prose)))
    return blocks, tokens


def field_failures(
    original: str | None, candidate: str | None, field: str
) -> list[str]:
    if original is None:
        return [] if candidate is None else [f"{field}: null must stay null"]
    if candidate is None:
        return [f"{field}: text was removed"]
    reasons = []
    blocks, tokens = markdown_parts(original)
    new_blocks, new_tokens = markdown_parts(candidate)
    if blocks != new_blocks:
        reasons.append(f"{field}: code blocks changed")
    if tokens - new_tokens:
        reasons.append(
            f"{field}: missing backtick spans: {', '.join(sorted(tokens - new_tokens))}"
        )
    if len(re.sub(r"\s", "", candidate)) > 2 * len(re.sub(r"\s", "", original)):
        reasons.append(f"{field}: exceeds twofold growth limit")
    return reasons


def rewrite_failures(original: dict, candidate: dict, verdicts: list) -> list[str]:
    reasons = []
    prefix = PREFIX.match(original["description"])
    rewritten_prefix = PREFIX.match(candidate["description"])
    if not prefix or not rewritten_prefix or prefix[0] != rewritten_prefix[0]:
        reasons.append("description: severity prefix changed")
    for field in FIELDS:
        reasons.extend(field_failures(original.get(field), candidate[field], field))
    if len(verdicts) != 1:
        reasons.append("missing or duplicate preservation verdict")
    else:
        verdict = verdicts[0]
        if type(verdict.get("preserved")) is not bool or not isinstance(
            verdict.get("notes"), str
        ):
            reasons.append("malformed preservation verdict")
        elif verdict["preserved"] is not True:
            reasons.append(verdict["notes"] or "meaning was not preserved")
    return reasons


def candidate_valid(candidate: dict) -> bool:
    return (
        type(candidate.get("unchanged")) is bool
        and isinstance(candidate.get("description"), str)
        and bool(candidate["description"].strip())
        and "proposed_fix" in candidate
        and (
            candidate["proposed_fix"] is None
            or isinstance(candidate["proposed_fix"], str)
        )
        and candidate.get("error") is None
    )


def merge(
    quality: dict, responses: list, verdicts: list, error: str | None = None
) -> dict:
    report = {
        "accepted_ids": [],
        "unchanged_ids": [],
        "reverted": [],
        "anomalies": [],
        "error": error,
    }
    expected = {item["id"] for item in quality["findings"]}
    candidates = index_entries(responses, expected, "response", report["anomalies"])
    decisions = index_entries(verdicts, expected, "preservation", report["anomalies"])
    findings = []
    for original in quality["findings"]:
        identifier = original["id"]
        entries = candidates.get(identifier, [])
        reasons = []
        candidate = entries[0] if len(entries) == 1 else None
        if error:
            reasons.append(error)
        elif candidate is None:
            reasons.append("missing or duplicate response")
        elif not candidate_valid(candidate):
            reasons.append("malformed response")
        elif candidate["unchanged"]:
            report["unchanged_ids"].append(identifier)
        else:
            reasons = rewrite_failures(
                original, candidate, decisions.get(identifier, [])
            )
            if not reasons:
                findings.append(
                    {**original, **{field: candidate[field] for field in FIELDS}}
                )
                report["accepted_ids"].append(identifier)
                continue
        findings.append(original)
        if reasons:
            report["reverted"].append({"id": identifier, "reasons": reasons})
    return {**quality, "findings": findings, "voice_preservation": report}


def read_quality(path: str, label: str) -> dict:
    quality = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(quality, dict) or not isinstance(quality.get("findings"), list):
        raise TypeError(f"{label} must be a finding-quality object")
    ids = []
    for item in quality["findings"]:
        if not isinstance(item, dict) or not valid_id(item.get("id")):
            raise ValueError(f"{label} findings need valid ids")
        if (
            not isinstance(item.get("description"), str)
            or not item["description"].strip()
        ):
            raise ValueError(f"{label} findings need non-empty descriptions")
        if item.get("proposed_fix") is not None and not isinstance(
            item["proposed_fix"], str
        ):
            raise ValueError(f"{label} proposed_fix must be text or null")
        ids.append(item["id"])
    if len(set(ids)) != len(ids):
        raise ValueError(f"{label} finding ids must be unique")
    return quality


def read_object(path: str, label: str) -> dict:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"{label} must be a JSON object")
    return value


def run_merge(original_path: str, responses_path: str, preservation_path: str) -> int:
    try:
        quality = read_quality(original_path, "original")
    except (OSError, TypeError, ValueError) as error:
        print(f"Invalid pre-voice snapshot: {error}", file=sys.stderr)
        return 1
    try:
        responses = read_array(responses_path, fenced=True)
        verdicts = read_array(preservation_path)
        result = merge(quality, responses, verdicts)
    except (OSError, TypeError, ValueError) as error:
        result = merge(quality, [], [], f"{type(error).__name__}: {error}")
    print(json.dumps(result, ensure_ascii=False))
    return 0


def run_repair(
    original_path: str,
    accepted_path: str,
    lint_path: str,
    responses_path: str,
    preservation_path: str,
) -> int:
    try:
        original = read_quality(original_path, "original")
        accepted = read_quality(accepted_path, "accepted")
    except (OSError, TypeError, ValueError) as error:
        print(f"Invalid repair snapshot: {error}", file=sys.stderr)
        return 1

    original_ids = [item["id"] for item in original["findings"]]
    accepted_ids = [item["id"] for item in accepted["findings"]]
    if set(original_ids) != set(accepted_ids):
        print("Invalid repair snapshot: finding ids differ", file=sys.stderr)
        return 1

    try:
        lint_result = read_object(lint_path, "lint result")
        target_ids = lint_result.get("warned_ids")
        if not isinstance(target_ids, list) or not all(
            valid_id(identifier) for identifier in target_ids
        ):
            raise TypeError("lint result warned_ids must be an array of valid ids")
        if len(set(target_ids)) != len(target_ids):
            raise ValueError("lint result warned_ids must be unique")
        unknown_ids = [
            identifier for identifier in target_ids if identifier not in original_ids
        ]
        if unknown_ids:
            raise ValueError(f"lint result has unknown ids: {unknown_ids}")
    except (OSError, TypeError, ValueError) as error:
        result = {
            **accepted,
            "voice_repair": {
                "target_ids": [],
                "accepted_ids": [],
                "unchanged_ids": [],
                "reverted": [],
                "anomalies": [],
                "error": f"{type(error).__name__}: {error}",
            },
        }
        print(json.dumps(result, ensure_ascii=False))
        return 0

    if lint_result.get("error") is not None:
        result = {
            **accepted,
            "voice_repair": {
                "target_ids": target_ids,
                "accepted_ids": [],
                "unchanged_ids": [],
                "reverted": [],
                "anomalies": [],
                "error": str(lint_result["error"]),
            },
        }
        print(json.dumps(result, ensure_ascii=False))
        return 0

    target_set = set(target_ids)
    limited = {
        **original,
        "findings": [item for item in original["findings"] if item["id"] in target_set],
    }
    try:
        responses = read_array(responses_path, fenced=True)
        verdicts = read_array(preservation_path)
        repaired = merge(limited, responses, verdicts)
    except (OSError, TypeError, ValueError) as error:
        repaired = merge(limited, [], [], f"{type(error).__name__}: {error}")

    replacements = {item["id"]: item for item in repaired["findings"]}
    report = {"target_ids": target_ids, **repaired["voice_preservation"]}
    result = {
        **accepted,
        "findings": [
            replacements.get(item["id"], item) for item in accepted["findings"]
        ],
        "voice_repair": report,
    }
    print(json.dumps(result, ensure_ascii=False))
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "repair":
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("original", help="Full immutable pre-voice object")
        parser.add_argument(
            "accepted", help="Full object accepted by the first voice pass"
        )
        parser.add_argument("lint", help="Voice linter result with warned_ids")
        parser.add_argument("responses", help="Repair response array")
        parser.add_argument("preservation", help="Repair preservation verdicts")
        args = parser.parse_args(sys.argv[2:])
        return run_repair(
            args.original,
            args.accepted,
            args.lint,
            args.responses,
            args.preservation,
        )

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", help="Full immutable finding-quality object")
    parser.add_argument("responses", help="Bare or four-backtick-fenced voice array")
    parser.add_argument("preservation", help="Orchestrator's semantic verdicts")
    args = parser.parse_args()
    return run_merge(args.original, args.responses, args.preservation)


if __name__ == "__main__":
    raise SystemExit(main())
