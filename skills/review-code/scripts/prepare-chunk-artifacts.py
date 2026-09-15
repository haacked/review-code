#!/usr/bin/env python3
"""Write scoped chunk metadata and a manifest without copying analysis payloads."""

import json
import sys
from pathlib import Path


def require_content(path):
    with path.open("rb") as source:
        if not source.read(1):
            raise ValueError(f"Empty artifact: {path}")


def prepare(session_path):
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
        files = set(chunk["files"])
        if not files:
            raise ValueError(f"No files for chunk: {chunk_id}")
        selected = [item for item in metadata if item["path"] in files]
        diff = Path(chunk["diff_path"]).absolute()
        require_content(diff)
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
                "diff_lines": diff_lines,
            }
        )
        scoped_metadata.append({"modified_files": selected})
    for record, scoped in zip(records, scoped_metadata):
        Path(record["metadata_path"]).write_text(json.dumps(scoped) + "\n")
    manifest = artifacts / "chunk-manifest.json"
    manifest.write_text(
        json.dumps(
            [
                {key: value for key, value in row.items() if key != "diff_lines"}
                for row in records
            ]
        )
        + "\n"
    )
    return {"manifest_path": str(manifest), "chunks": records}


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: prepare-chunk-artifacts.py SESSION_FILE")
        print(json.dumps(prepare(sys.argv[1])))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
