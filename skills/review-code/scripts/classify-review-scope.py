"""Select reviewers conservatively from full-diff explorer evidence."""

import argparse
import json
import subprocess
import sys
from copy import deepcopy
from pathlib import Path

from helpers.markdown_fences import FENCE, walk_fences

AREAS = (
    "security",
    "performance",
    "correctness",
    "maintainability",
    "testing",
    "compatibility",
    "architecture",
    "infra-config",
    "frontend",
)


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def read_routing(path):
    if path is None:
        return {}, "Explorer evidence not supplied"
    try:
        context = Path(path).read_text()
        blocks = []
        block = None
        for _, line, kind in walk_fences(context.splitlines(keepends=True)):
            if (
                kind == "open"
                and line[FENCE.match(line).end() :].strip() == "review-routing"
            ):
                block = []
            elif block is not None and kind == "close":
                blocks.append("".join(block))
                block = None
            elif block is not None:
                block.append(line)
        if block is not None or len(blocks) != 1:
            raise ValueError("expected exactly one review-routing block")
        routing = json.loads(blocks[0], object_pairs_hook=unique_keys)
        if (
            not isinstance(routing, dict)
            or routing.get("scope") != "full"
            or not isinstance(routing.get("areas"), dict)
        ):
            raise ValueError("routing must contain full scope and an areas object")
        return routing["areas"], "Explorer did not assess this area"
    except (OSError, UnicodeError, ValueError) as error:
        return {}, f"Explorer routing unavailable: {error}"


def valid_evidence(evidence):
    return (
        isinstance(evidence, list)
        and bool(evidence)
        and all(
            isinstance(item, dict)
            and all(
                isinstance(item.get(key), str) and item[key].strip()
                for key in ("check", "result")
            )
            for item in evidence
        )
    )


def decide(area, assessment, fallback_reason):
    evidence = assessment.get("evidence") if isinstance(assessment, dict) else None
    evidence = evidence if valid_evidence(evidence) else []
    if area == "correctness":
        reason = "Correctness always runs"
    elif assessment is None:
        reason = fallback_reason
    elif not isinstance(assessment, dict):
        reason = "Missing or invalid explorer assessment; reviewer required"
    elif assessment.get("status") == "not_applicable" and evidence:
        return {
            "decision": "skip",
            "reason": "Explorer ruled out this area: "
            + "; ".join(item["result"] for item in evidence),
            "evidence": evidence,
        }
    elif assessment.get("status") == "applies":
        reason = "Explorer identified applicable changes"
    elif assessment.get("status") == "uncertain":
        reason = "Explorer is uncertain; reviewer required"
    else:
        reason = "No valid negative evidence; reviewer required"
    return {"decision": "run", "reason": reason, "evidence": evidence}


def classify(session, assessments, fallback_reason):
    tokens = session.get("diff_tokens") or 0
    files = (session.get("file_metadata") or {}).get("modified_files") or []
    depth = "minimal" if tokens < 500 else "standard" if tokens < 2000 else "thorough"
    if files and all(file.get("is_infra_config") is True for file in files):
        depth = "minimal"
    decisions = {
        area: decide(area, assessments.get(area), fallback_reason) for area in AREAS
    }
    agents = [area for area in AREAS if decisions[area]["decision"] == "run"]
    skipped = [area for area in AREAS if decisions[area]["decision"] == "skip"]
    return {
        "exploration_depth": depth,
        "agents": agents,
        "skipped_agents": skipped,
        "reasoning": (
            "Correctness always runs; specialists require concrete negative evidence to skip. "
            f"Running {len(agents)} reviewers; skipping {len(skipped)}."
        ),
        "agent_decisions": decisions,
    }


def session_for_patch(session, patch_path):
    if patch_path is None:
        return session
    patch = Path(patch_path).read_bytes()
    metadata = json.loads(
        subprocess.check_output(
            [str(Path(__file__).with_name("pre-review-context.sh"))], input=patch
        )
    )
    scoped = deepcopy(session)
    scoped["diff_tokens"] = len(patch) // 4
    scoped["file_metadata"] = metadata
    return scoped


def apply_area_override(result, requested_area):
    if requested_area is None:
        return result

    selected = list(dict.fromkeys(("correctness", requested_area)))
    reason = f"Explicit user scope override: requested area '{requested_area}'"
    decisions = {
        area: {
            "decision": "run" if area in selected else "skip",
            "reason": "Correctness always runs" if area == "correctness" else reason,
            "evidence": [],
        }
        for area in AREAS
    }
    return {
        **result,
        "exploration_depth": "standard",
        "agents": selected,
        "skipped_agents": [area for area in AREAS if area not in selected],
        "reasoning": f"Correctness always runs. {reason}",
        "agent_decisions": decisions,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session_file")
    parser.add_argument("--diff-file")
    parser.add_argument("--explorer-context")
    parser.add_argument("--area", choices=AREAS)
    args = parser.parse_args()
    try:
        with open(args.session_file) as source:
            session = json.load(source)
        session = session_for_patch(session, args.diff_file)
        assessments, fallback_reason = read_routing(args.explorer_context)
        result = apply_area_override(
            classify(session, assessments, fallback_reason), args.area
        )
    except (
        OSError,
        ValueError,
        TypeError,
        AttributeError,
        subprocess.CalledProcessError,
    ) as error:
        json.dump({"error": str(error)}, sys.stdout)
        sys.stdout.write("\n")
        parser.exit(1, f"review scope classification: {error}\n")
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
