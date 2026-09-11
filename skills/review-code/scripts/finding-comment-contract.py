#!/usr/bin/env python3
"""Validate causal findings, apply gate verdicts, and prepare publication."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from pathlib import Path
from typing import Any

SEVERITIES = ("blocking", "suggestion", "question", "nit")
FACT_FIELDS = (
    "problem",
    "trigger",
    "mechanism",
    "result",
    "requested_change",
    "regression_case",
    "regression_rationale",
)


def read_json(path: str) -> Any:
    if path == "-":
        return json.load(sys.stdin)
    return json.loads(Path(path).read_text(encoding="utf-8"))


def text(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped or None


def valid_identifier(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return True
    return isinstance(value, str) and bool(value.strip())


def validate_facts(item: dict[str, Any]) -> list[str]:
    reasons: list[str] = []
    identifier = item.get("id")
    if not valid_identifier(identifier):
        reasons.append("id must be a non-empty string or integer")
    if item.get("comment_style", "concise") not in ("concise", "detailed"):
        reasons.append("comment_style must be concise or detailed")
    severity = item.get("severity")
    if severity not in SEVERITIES:
        reasons.append("severity must be blocking, suggestion, question, or nit")
    if not text(item.get("description")):
        reasons.append("description is required")

    if text(item.get("location")):
        if not text(item.get("file")):
            reasons.append("file must be a non-empty string")
        line = item.get("line")
        if isinstance(line, bool) or not isinstance(line, int) or line < 1:
            reasons.append("line must be a positive integer")

    facts = item.get("facts")
    if not isinstance(facts, dict):
        return reasons + ["facts must be an object"]

    missing_fields = [field for field in FACT_FIELDS if field not in facts]
    if missing_fields:
        reasons.append(f"facts are missing fields: {', '.join(missing_fields)}")

    mechanism = facts.get("mechanism")
    if not isinstance(mechanism, list) or any(not text(step) for step in mechanism):
        reasons.append("mechanism must be an array of non-empty causal steps")

    if severity in ("blocking", "suggestion"):
        for field in ("problem", "result", "requested_change"):
            if not text(facts.get(field)):
                reasons.append(f"{field} is required for {severity} findings")
        if not isinstance(mechanism, list) or not mechanism:
            reasons.append(f"mechanism needs at least one step for {severity} findings")
    else:
        if not text(facts.get("problem")):
            reasons.append(f"problem is required for {severity} findings")
        if not text(facts.get("requested_change")):
            reasons.append(f"requested_change is required for {severity} findings")

    if severity == "blocking" and not (
        text(facts.get("regression_case")) or text(facts.get("regression_rationale"))
    ):
        reasons.append(
            "blocking findings need a regression case or a rationale for omitting one"
        )
    return reasons


def withheld(item: Any, state: str, reasons: list[str]) -> dict[str, Any]:
    result = dict(item) if isinstance(item, dict) else {"input": item}
    result["publishable"] = False
    result["quality_state"] = state
    result["reasons"] = reasons
    return result


def compose(items: Any) -> dict[str, list[dict[str, Any]]]:
    if not isinstance(items, list):
        raise ValueError("compose input must be a JSON array")

    identifier_counts: dict[Any, int] = {}
    for item in items:
        if isinstance(item, dict) and valid_identifier(item.get("id")):
            identifier = item["id"]
            identifier_counts[identifier] = identifier_counts.get(identifier, 0) + 1

    findings: list[dict[str, Any]] = []
    withheld_findings: list[dict[str, Any]] = []
    for raw in items:
        if not isinstance(raw, dict):
            withheld_findings.append(
                withheld(raw, "invalid_contract", ["finding must be an object"])
            )
            continue
        reasons = validate_facts(raw)
        try:
            body = publication_body(raw)
            if not body:
                reasons.append(
                    "description must contain text after its severity prefix"
                )
        except ValueError as exc:
            reasons.append(str(exc))
        if valid_identifier(raw.get("id")) and identifier_counts[raw["id"]] > 1:
            reasons.append("id must be unique")
        if reasons:
            withheld_findings.append(withheld(raw, "invalid_contract", reasons))
            continue
        finding = dict(raw)
        finding["description"] = body
        finding.setdefault("comment_style", "concise")
        finding["publishable"] = False
        finding["quality_state"] = "ungated"
        findings.append(finding)
    return {
        "findings": findings,
        "rewrites_needed": [],
        "withheld": withheld_findings,
    }


def applicable_coverage(item: dict[str, Any]) -> list[str]:
    facts = item["facts"]
    if item.get("comment_style", "concise") == "concise":
        return [
            field
            for field in ("problem", "trigger", "requested_change")
            if text(facts.get(field))
        ]
    fields = [
        field
        for field in (
            "problem",
            "trigger",
            "result",
            "requested_change",
            "regression_case",
        )
        if text(facts.get(field))
    ]
    if facts.get("mechanism"):
        fields.append("mechanism")
    return fields


def verdict_map(verdicts: Any) -> dict[Any, dict[str, Any]]:
    if not isinstance(verdicts, list):
        return {}
    mapped: dict[Any, dict[str, Any]] = {}
    duplicates: set[Any] = set()
    for verdict in verdicts:
        if not isinstance(verdict, dict) or "id" not in verdict:
            continue
        identifier = verdict["id"]
        if not valid_identifier(identifier):
            continue
        if identifier in mapped:
            duplicates.add(identifier)
        mapped[identifier] = verdict
    for identifier in duplicates:
        mapped.pop(identifier, None)
    return mapped


def evaluate_verdict(
    item: dict[str, Any], verdict: dict[str, Any] | None
) -> tuple[str, list[str]]:
    if verdict is None:
        return "gate_error", ["semantic gate returned no unique verdict"]
    if verdict.get("verdict") not in {"PASS", "REWRITE"}:
        return "gate_error", ["semantic gate returned an invalid verdict"]
    coverage = verdict.get("coverage")
    if not isinstance(coverage, dict):
        return "gate_error", ["semantic gate returned no coverage object"]
    inference_required = verdict.get("inference_required")
    if not isinstance(inference_required, bool):
        return "gate_error", ["semantic gate returned no inference decision"]

    uncovered = [
        field for field in applicable_coverage(item) if coverage.get(field) is not True
    ]
    if verdict["verdict"] == "PASS" and not inference_required and not uncovered:
        return "passed", []

    reasons = []
    if uncovered:
        reasons.append(f"body does not explicitly cover: {', '.join(uncovered)}")
    if inference_required:
        reasons.append("body requires the reader to infer a causal relationship")
    if verdict["verdict"] == "REWRITE":
        reasons.append(
            text(verdict.get("notes")) or "semantic gate requested a rewrite"
        )
    return "rewrite_required", reasons


def gate(composed: Any, verdicts: Any, final: bool) -> dict[str, list[dict[str, Any]]]:
    if not isinstance(composed, dict) or not isinstance(composed.get("findings"), list):
        raise ValueError("gate input must be compose output")

    publishable: list[dict[str, Any]] = []
    rewrites: list[dict[str, Any]] = []
    withheld_findings = [
        dict(item) for item in composed.get("withheld", []) if isinstance(item, dict)
    ]
    verdicts_by_id = verdict_map(verdicts)

    for item in composed["findings"]:
        state, reasons = evaluate_verdict(item, verdicts_by_id.get(item.get("id")))
        result = dict(item)
        if state == "passed":
            result["publishable"] = True
            result["quality_state"] = state
            result["reasons"] = []
            publishable.append(result)
        elif state == "gate_error":
            withheld_findings.append(withheld(result, state, reasons))
        elif final:
            withheld_findings.append(withheld(result, "rewrite_failed", reasons))
        else:
            rewrites.append(withheld(result, state, reasons))

    return {
        "findings": publishable,
        "rewrites_needed": rewrites,
        "withheld": withheld_findings,
    }


def publication_body(item: dict[str, Any]) -> str:
    severity = item.get("severity")
    if severity not in SEVERITIES:
        raise ValueError("severity must be blocking, suggestion, question, or nit")
    body = text(item.get("description")) or ""
    if not body:
        return ""
    prefix = re.match(
        r"^(?:`(blocking|suggestion|question|nit)(?::`|`:)|"
        r"\*\*(blocking|suggestion|question|nit)(?::\*\*|\*\*:)|"
        r"(blocking|suggestion|question|nit):)\s*",
        body,
        re.IGNORECASE,
    )
    if prefix:
        existing = next(group for group in prefix.groups() if group).lower()
        if existing != severity:
            raise ValueError("body prefix does not match severity")
        body = body[prefix.end() :]
        if not body:
            return ""
    return f"`{severity}`: {body}"


def publish(quality: Any) -> dict[str, Any]:
    if not isinstance(quality, dict):
        raise ValueError("publish input must be a finding quality object")
    if not isinstance(quality.get("findings"), list):
        raise ValueError("publish input must contain a findings array")

    withheld_findings = [
        dict(item) for item in quality.get("withheld", []) if isinstance(item, dict)
    ]
    withheld_findings.extend(
        dict(item)
        for item in quality.get("rewrites_needed", [])
        if isinstance(item, dict)
    )
    publishable_findings: list[dict[str, Any]] = []
    comments: list[dict[str, Any]] = []

    for raw in quality["findings"]:
        if not isinstance(raw, dict):
            withheld_findings.append(
                withheld(raw, "publication_failed", ["finding must be an object"])
            )
            continue
        if raw.get("publishable") is not True:
            withheld_findings.append(dict(raw))
            continue

        reasons: list[str] = []
        file = text(raw.get("file"))
        line = raw.get("line")
        try:
            body = publication_body(raw)
        except ValueError as exc:
            body = ""
            reasons.append(str(exc))
        if not file:
            reasons.append("file must be a non-empty string")
        if isinstance(line, bool) or not isinstance(line, int) or line < 1:
            reasons.append("line must be a positive integer")
        if not body:
            reasons.append("public body must be a non-empty string")
        if reasons:
            withheld_findings.append(withheld(raw, "publication_failed", reasons))
            continue

        finding = dict(raw)
        finding["description"] = body
        publishable_findings.append(finding)
        comment: dict[str, Any] = {"path": file, "line": line, "body": body}
        if text(raw.get("side")):
            comment["side"] = raw["side"]
        if isinstance(raw.get("line_content"), str):
            comment["line_content"] = raw["line_content"]
        comments.append(comment)

    return {
        "findings": publishable_findings,
        "comments": comments,
        "unmapped_comments": [],
        "withheld": withheld_findings,
        "all_withheld": not publishable_findings and bool(withheld_findings),
        "clean": not publishable_findings and not withheld_findings,
    }


def validate_publication_comment(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("publication comments must be objects")
    path = text(raw.get("path"))
    line = raw.get("line")
    body = text(raw.get("body"))
    if not path or isinstance(line, bool) or not isinstance(line, int) or line < 1:
        raise ValueError("publication comments must have valid path and line fields")
    if not body:
        raise ValueError("publication comments must have a non-empty body")
    return raw


def parse_diff(path: str) -> tuple[dict[tuple[str, int], str], list[str]]:
    contents: dict[tuple[str, int], str] = {}
    paths: list[str] = []
    current_path: str | None = None
    pending_path_pair: tuple[str, str] | None = None
    new_line: int | None = None

    def add_path(changed_path: str) -> None:
        if changed_path not in paths:
            paths.append(changed_path)

    for raw_line in Path(path).read_text(encoding="utf-8").splitlines():
        if raw_line.startswith("diff --git "):
            if pending_path_pair:
                add_path(pending_path_pair[1])
            parts = shlex.split(raw_line)
            if (
                len(parts) != 4
                or not parts[2].startswith("a/")
                or not parts[3].startswith("b/")
            ):
                raise ValueError("could not parse a path from the diff")
            old_path = parts[2][2:]
            current_path = parts[3][2:]
            if old_path == current_path:
                add_path(current_path)
                pending_path_pair = None
            else:
                pending_path_pair = (old_path, current_path)
            new_line = None
            continue
        if raw_line.startswith("rename from ") and pending_path_pair:
            add_path(pending_path_pair[0])
            add_path(pending_path_pair[1])
            pending_path_pair = None
            continue
        if raw_line.startswith("copy from ") and pending_path_pair:
            add_path(pending_path_pair[1])
            pending_path_pair = None
            continue
        if raw_line.startswith("@@"):
            match = re.search(r"\+(\d+)", raw_line)
            new_line = int(match.group(1)) if match else None
            continue
        if current_path is None or new_line is None:
            continue
        if raw_line.startswith("+") and not raw_line.startswith("+++"):
            contents[(current_path, new_line)] = raw_line[1:]
            new_line += 1
        elif raw_line.startswith(" "):
            contents[(current_path, new_line)] = raw_line[1:]
            new_line += 1
        elif raw_line.startswith("-") and not raw_line.startswith("---"):
            continue
    if pending_path_pair:
        add_path(pending_path_pair[1])
    return contents, paths


def draft(draft_input: Any) -> dict[str, Any]:
    if not isinstance(draft_input, dict):
        raise ValueError("draft input must be an object")
    publication = draft_input.get("publication")
    if not isinstance(publication, dict):
        raise ValueError("draft input must contain a publication object")
    raw_comments = publication.get("comments")
    if not isinstance(raw_comments, list):
        raise ValueError("publication must contain a comments array")
    publication_comments = [
        validate_publication_comment(comment) for comment in raw_comments
    ]
    unmapped_comments = publication.get("unmapped_comments", [])
    if not isinstance(unmapped_comments, list):
        raise ValueError("publication unmapped_comments must be an array")
    unmapped_comments = list(unmapped_comments)

    selected_indices = draft_input.get("selected_indices")
    if selected_indices is None:
        selected_indices = list(range(len(publication_comments)))
    if not isinstance(selected_indices, list):
        raise ValueError("selected_indices must be an array")
    for index in selected_indices:
        if (
            isinstance(index, bool)
            or not isinstance(index, int)
            or index < 0
            or index >= len(publication_comments)
        ):
            raise ValueError("selected index is outside the publication comments array")
    if len(set(selected_indices)) != len(selected_indices):
        raise ValueError("selected_indices must be unique")

    mappings = draft_input.get("mappings", [])
    if not isinstance(mappings, list):
        raise ValueError("mappings must be an array")
    if len(mappings) != len(selected_indices):
        raise ValueError("mappings must have one entry per selected comment")

    comments: list[dict[str, Any]] = []
    for index, mapping in zip(selected_indices, mappings, strict=True):
        source = publication_comments[index]
        if not isinstance(mapping, dict):
            raise ValueError("mapping entries must be objects")
        if (
            mapping.get("path") != source["path"]
            or mapping.get("line") != source["line"]
        ):
            raise ValueError("mapping does not match its publication comment")
        if text(mapping.get("error")):
            unmapped_comments.append({"description": source["body"]})
            continue

        comment = {
            "path": source["path"],
            "line": source["line"],
            "body": source["body"],
        }
        side = mapping.get("side")
        if side not in {None, "LEFT", "RIGHT"}:
            raise ValueError("mapping side must be LEFT or RIGHT")
        if side:
            comment["side"] = side
        if isinstance(source.get("line_content"), str):
            comment["line_content"] = source["line_content"]
        comments.append(comment)

    context = draft_input.get("context")
    if not isinstance(context, dict):
        raise ValueError("draft input must contain a context object")
    for field in ("owner", "repo", "reviewer_username"):
        if not text(context.get(field)):
            raise ValueError(f"context {field} must be a non-empty string")
    pr_number = context.get("pr_number")
    if isinstance(pr_number, bool) or not isinstance(pr_number, (int, str)):
        raise ValueError("context pr_number must be a string or integer")

    result = dict(context)
    diff_path = text(result.get("original_diff_path"))
    delta_paths: list[str] = []
    if diff_path:
        line_contents, delta_paths = parse_diff(diff_path)
        for comment in comments:
            line_content = line_contents.get((comment["path"], comment["line"]))
            if line_content is not None:
                comment["line_content"] = line_content
    if result.get("append") is True:
        if not diff_path:
            raise ValueError("append drafts require original_diff_path")
        if not delta_paths:
            raise ValueError("append diff contains no changed paths")
        result["delta_paths"] = delta_paths
    result["comments"] = comments
    result["unmapped_comments"] = unmapped_comments
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    compose_parser = subparsers.add_parser("compose")
    compose_parser.add_argument("input")
    gate_parser = subparsers.add_parser("gate")
    gate_parser.add_argument("--final", action="store_true")
    gate_parser.add_argument("composed")
    gate_parser.add_argument("verdicts")
    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("quality")
    draft_parser = subparsers.add_parser("draft")
    draft_parser.add_argument("input")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "compose":
        result = compose(read_json(args.input))
    elif args.command == "gate":
        result = gate(
            read_json(args.composed), read_json(args.verdicts), final=args.final
        )
    elif args.command == "publish":
        result = publish(read_json(args.quality))
    else:
        result = draft(read_json(args.input))
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
