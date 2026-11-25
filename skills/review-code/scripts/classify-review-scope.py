"""Select reviewers conservatively from full-diff explorer evidence."""

import argparse
import json
import subprocess
import sys
from copy import deepcopy
from pathlib import Path

from helpers.markdown_fences import FENCE, walk_fences
from helpers.review_tracks import (
    SPEC_TRACK_AREAS,
    parse_patch,
    path_kind,
    security_hits,
    spec_paths,
)

AREAS = (
    "security",
    "performance",
    "correctness",
    "maintainability",
    "testing",
    "compatibility",
    "infra-config",
    "frontend",
    "spec",
)
TABLE_CHECK = "Classified every changed path with helpers/review_tracks.py"
SPEC_TRACK_REASON = "Spec track: every changed file is spec content"


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


def read_patch(path):
    if not isinstance(path, str) or not path:
        return None
    try:
        with open(path, newline="") as source:
            return source.read()
    except (OSError, UnicodeError):
        return None


def modified_files(session):
    return (session.get("file_metadata") or {}).get("modified_files") or []


def changed_paths(session):
    return [
        item["path"]
        for item in modified_files(session)
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    ]


def metadata_blockers(whole_session, session):
    blockers = []
    for label, files in (
        ("review", modified_files(whole_session)),
        ("reviewed patch", modified_files(session)),
    ):
        if not files:
            blockers.append(f"the {label} lists no changed files")
        for item in files:
            if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                blockers.append(f"the {label} has an unreadable file entry")
                continue
            if item.get("is_infra_config") is True:
                blockers.append(f"{item['path']} is infrastructure config")
            kind, reason = path_kind(item["path"])
            if kind != "spec":
                blockers.append(f"{item['path']} is code: {reason}")
    return blockers


def decide_track(whole_session, session, reviewed_patch_path):
    """Return the blockers that keep the review off the spec track, and the parsed reviewed patch.

    The spec track needs every changed file in the whole review and in the
    reviewed patch to be spec content. A chunk or delta that holds only prose
    therefore stays on the code track when the rest of the review changed code.
    The patches are read only when the file metadata allows the spec track.
    """
    blockers = metadata_blockers(whole_session, session)
    if blockers:
        return list(dict.fromkeys(blockers)), None
    whole_path = whole_session.get("diff_path")
    whole_patch = read_patch(whole_path)
    if whole_patch is None:
        return ["the session's diff_path is missing or unreadable"], None
    reviewed_path = reviewed_patch_path or session.get("diff_path")
    reviewed_patch = (
        whole_patch if reviewed_path == whole_path else read_patch(reviewed_path)
    )
    if reviewed_patch is None:
        return ["the reviewed patch is unreadable"], None
    reviewed = parse_patch(reviewed_patch)
    blockers = list(reviewed["blockers"])
    if reviewed_patch is not whole_patch:
        blockers.extend(parse_patch(whole_patch)["blockers"])
    return list(dict.fromkeys(blockers)), reviewed


def spec_decision(paths):
    matched = spec_paths(paths)
    if not matched:
        return {
            "decision": "skip",
            "reason": "No changed path is spec content",
            "evidence": [
                {"check": TABLE_CHECK, "result": "No changed path is spec content"}
            ],
        }
    shown = ", ".join(matched[:5]) + (", …" if len(matched) > 5 else "")
    result = f"{len(matched)} paths are spec content: {shown}"
    return {
        "decision": "run",
        "reason": result,
        "evidence": [{"check": TABLE_CHECK, "result": result}],
    }


def apply_spec_track(decisions, session, reviewed, assessments):
    paths = changed_paths(session)
    evidence = [
        {
            "check": TABLE_CHECK,
            "result": f"All {len(paths)} changed paths are spec content; no code changed",
        }
    ]
    skip = {"decision": "skip", "reason": SPEC_TRACK_REASON, "evidence": evidence}
    for area in AREAS:
        if area not in SPEC_TRACK_AREAS and area != "security":
            decisions[area] = deepcopy(skip)
    hits = security_hits(reviewed, paths)
    if hits:
        decisions["security"] = {
            "decision": "run",
            "reason": "Spec track: the change names security terms: "
            + ", ".join(hits[:5]),
            "evidence": [],
        }
    elif not (
        isinstance(assessments.get("security"), dict)
        and assessments["security"].get("status") == "applies"
    ):
        decisions["security"] = deepcopy(skip)
        decisions["security"]["evidence"] = evidence + [
            {
                "check": "Searched changed lines and paths for auth, credential, token, and personal-data terms",
                "result": "No security term found",
            }
        ]


def classify(session, assessments, fallback_reason, whole_session, reviewed_patch_path):
    tokens = session.get("diff_tokens") or 0
    files = modified_files(session)
    depth = "minimal" if tokens < 500 else "standard" if tokens < 2000 else "thorough"
    if files and all(file.get("is_infra_config") is True for file in files):
        depth = "minimal"
    decisions = {
        area: decide(area, assessments.get(area), fallback_reason)
        for area in AREAS
        if area != "spec"
    }
    decisions["spec"] = spec_decision(changed_paths(session))
    blockers, reviewed = decide_track(whole_session, session, reviewed_patch_path)
    track = "code" if blockers else "spec"
    if track == "spec":
        apply_spec_track(decisions, session, reviewed, assessments)
    agents = [area for area in AREAS if decisions[area]["decision"] == "run"]
    skipped = [area for area in AREAS if decisions[area]["decision"] == "skip"]
    track_reason = (
        f"{SPEC_TRACK_REASON}."
        if track == "spec"
        else "Code track: " + "; ".join(blockers[:3]) + "."
    )
    return {
        "exploration_depth": depth,
        "track": track,
        "agents": agents,
        "skipped_agents": skipped,
        "reasoning": (
            f"{track_reason} Correctness always runs; specialists require concrete negative evidence to skip. "
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


def caller_reviewers(session):
    reviewers = session.get("reviewers")
    if reviewers is None:
        return None
    if (
        not isinstance(reviewers, list)
        or not reviewers
        or any(area not in AREAS for area in reviewers)
    ):
        raise ValueError("session reviewers must be a non-empty list of known areas")
    return reviewers


def apply_scope_override(result, selected, run_reason, skip_reason, reasoning):
    selected = list(dict.fromkeys(("correctness", *selected)))
    decisions = {
        area: {
            "decision": "run" if area in selected else "skip",
            "reason": "Correctness always runs"
            if area == "correctness"
            else run_reason
            if area in selected
            else skip_reason,
            "evidence": [],
        }
        for area in AREAS
    }
    return {
        **result,
        "track": "code",
        "agents": selected,
        "skipped_agents": [area for area in AREAS if area not in selected],
        "reasoning": f"Correctness always runs. {reasoning}",
        "agent_decisions": decisions,
    }


def apply_area_override(result, requested_area):
    if requested_area is None:
        return result
    reason = f"Explicit user scope override: requested area '{requested_area}'"
    return {
        **apply_scope_override(result, [requested_area], reason, reason, reason),
        "exploration_depth": "standard",
    }


def apply_reviewers_override(result, reviewers):
    if reviewers is None:
        return result
    listed = ",".join(dict.fromkeys(("correctness", *reviewers)))
    return apply_scope_override(
        result,
        reviewers,
        f"Requested by the caller's --reviewers list ({listed})",
        f"Excluded by the caller's --reviewers list ({listed}); this area was not reviewed",
        f"The caller's --reviewers list ({listed}) excluded every other reviewer, "
        "so their areas were not reviewed.",
    )


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
        whole_session = session
        session = session_for_patch(session, args.diff_file)
        assessments, fallback_reason = read_routing(args.explorer_context)
        if args.area is not None and session.get("reviewers") is not None:
            raise ValueError("an area argument and --reviewers cannot both apply")
        result = apply_reviewers_override(
            apply_area_override(
                classify(
                    session, assessments, fallback_reason, whole_session, args.diff_file
                ),
                args.area,
            ),
            caller_reviewers(session),
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
