#!/usr/bin/env python3
"""Write scoped chunk metadata and a manifest without copying analysis payloads."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

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

MANIFEST_FIELDS = (
    "id",
    "label",
    "files",
    "diff_path",
    "metadata_path",
    "analysis_path",
)


def require_content(path):
    with path.open("rb") as source:
        if not source.read(1):
            raise ValueError(f"Empty artifact: {path}")


def classify_chunk(session_path, record, area):
    command = [
        str(Path(__file__).with_name("classify-review-scope.sh")),
        str(session_path),
        "--diff-file",
        record["diff_path"],
        "--explorer-context",
        record["analysis_path"],
    ]
    if area:
        command.extend(["--area", area])
    try:
        output = subprocess.check_output(command, text=True)
    except subprocess.CalledProcessError:
        command = [
            item
            for item in command
            if item not in ("--explorer-context", record["analysis_path"])
        ]
        output = subprocess.check_output(command, text=True)
    classification = json.loads(output)
    Path(record["routing_path"]).write_text(json.dumps(classification) + "\n")
    return classification


def aggregate_routing(records, artifacts):
    agents = [
        area
        for area in AREAS
        if any(area in record["classification"]["agents"] for record in records)
    ]
    skipped = [area for area in AREAS if area not in agents]
    decisions = {}
    for area in AREAS:
        matching = [
            record for record in records if area in record["classification"]["agents"]
        ]
        if matching:
            labels = ", ".join(record["label"] for record in matching)
            decisions[area] = {
                "decision": "run",
                "reason": f"Runs for chunks: {labels}",
                "evidence": [],
            }
            continue
        evidence = []
        for record in records:
            evidence.extend(
                record["classification"]["agent_decisions"][area]["evidence"]
            )
        decisions[area] = {
            "decision": "skip",
            "reason": "Every chunk supplied concrete negative evidence or the user excluded this area",
            "evidence": evidence,
        }
    aggregate = {
        "scope": "chunks",
        "agents": agents,
        "skipped_agents": skipped,
        "reasoning": (
            "Each chunk was routed from its own explorer evidence. "
            f"Running {len(agents)} reviewers across the review; skipping {len(skipped)} everywhere."
        ),
        "agent_decisions": decisions,
        "chunks": [
            {
                "id": record["id"],
                "label": record["label"],
                "routing_path": record["routing_path"],
                "classification": record["classification"],
            }
            for record in records
        ],
    }
    (artifacts / "review-routing.json").write_text(json.dumps(aggregate) + "\n")
    return aggregate


def prepare(session_path, classify=False, area=None):
    session = json.loads(Path(session_path).read_text())
    artifacts = Path(session["artifacts_dir"]).absolute()
    require_content(artifacts / "architectural-context.md")
    chunks = session["chunks"]
    if not chunks:
        raise ValueError("No chunks to prepare")
    metadata = session["file_metadata"]["modified_files"]
    records = []
    scoped_metadata = []
    seen_ids = set()
    for index, chunk in enumerate(chunks):
        chunk_id = chunk["id"]
        if chunk_id in seen_ids:
            raise ValueError(f"Duplicate chunk id: {chunk_id}")
        seen_ids.add(chunk_id)
        if not chunk["files"]:
            raise ValueError(f"No files for chunk: {chunk_id}")
        diff = Path(chunk["diff_path"]).absolute()
        require_content(diff)
        patch_metadata = json.loads(
            subprocess.check_output(
                [str(Path(__file__).with_name("pre-review-context.sh"))],
                input=diff.read_bytes(),
            )
        )
        session_by_path = {item["path"]: item for item in metadata}
        selected = [
            {**session_by_path.get(item["path"], {}), **item}
            for item in patch_metadata["modified_files"]
        ]
        with diff.open("rb") as source:
            diff_lines = sum(1 for _ in source)
        records.append(
            {
                "id": chunk_id,
                "label": chunk["label"],
                "files": chunk["files"],
                "diff_path": str(diff),
                "metadata_path": str(artifacts / f"chunk-{index}-metadata.json"),
                "analysis_path": str(artifacts / f"chunk-{index}-analysis.md"),
                "routing_path": str(artifacts / f"chunk-{index}-routing.json"),
                "diff_lines": diff_lines,
            }
        )
        scoped_metadata.append({"modified_files": selected})
    for record, scoped in zip(records, scoped_metadata):
        Path(record["metadata_path"]).write_text(json.dumps(scoped) + "\n")
    manifest = artifacts / "chunk-manifest.json"
    manifest.write_text(
        json.dumps(
            [{field: row[field] for field in MANIFEST_FIELDS} for row in records]
        )
        + "\n"
    )
    result = {
        "manifest_path": str(manifest),
        "chunks": records,
    }
    if classify:
        for record in records:
            require_content(Path(record["analysis_path"]))
            record["classification"] = classify_chunk(session_path, record, area)
        aggregate = aggregate_routing(records, artifacts)
        result.update(
            {
                "agents": aggregate["agents"],
                "skipped_agents": aggregate["skipped_agents"],
                "reasoning": aggregate["reasoning"],
            }
        )
    return result


if __name__ == "__main__":
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("session_file")
        parser.add_argument("--classify", action="store_true")
        parser.add_argument("--area", choices=AREAS)
        args = parser.parse_args()
        print(json.dumps(prepare(args.session_file, args.classify, args.area)))
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
