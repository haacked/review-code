#!/usr/bin/env python3
"""Select one review dispatch route from compact orchestration fields."""

import argparse
import json
import sys

AREAS = {
    "security",
    "performance",
    "correctness",
    "maintainability",
    "testing",
    "compatibility",
    "architecture",
    "infra-config",
    "frontend",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fields", required=True)
    parser.add_argument("--agents", required=True)
    parser.add_argument("--review-mode", choices=("full", "delta"), default="full")
    args = parser.parse_args()
    try:
        with open(args.fields) as source:
            fields = json.load(source)
        areas = list(dict.fromkeys(args.agents.split()))
        if not areas or any(area not in AREAS for area in areas):
            raise ValueError("agents must name known review areas")
        if args.review_mode == "delta":
            metadata = {}
            chunked = False
        else:
            metadata = fields.get("chunk_metadata")
            if metadata is None:
                metadata = {}
            elif not isinstance(metadata, dict):
                raise ValueError("chunk_metadata must be an object")
            chunked = metadata.get("chunked", False)
            if not isinstance(chunked, bool):
                raise ValueError("chunked must be a boolean")
        if chunked:
            chunks = fields.get("chunks")
            count = metadata.get("chunk_count")
            if (
                not isinstance(chunks, list)
                or not chunks
                or type(count) is not int
                or count != len(chunks)
            ):
                raise ValueError(
                    "chunked review requires chunks and matching chunk_count"
                )
            for chunk in chunks:
                if (
                    not isinstance(chunk, dict)
                    or type(chunk.get("id")) is not int
                    or not isinstance(chunk.get("label"), str)
                    or not chunk["label"]
                    or not isinstance(chunk.get("files"), list)
                    or not chunk["files"]
                    or any(
                        not isinstance(path, str) or not path for path in chunk["files"]
                    )
                    or not isinstance(chunk.get("diff_path"), str)
                    or not chunk["diff_path"]
                ):
                    raise ValueError("chunked review requires valid chunk records")
            if [chunk["id"] for chunk in chunks] != list(range(1, count + 1)):
                raise ValueError("chunked review requires sequential chunk IDs")
            result = {"handler": "review-chunked.md", "agents": []}
        else:
            result = {
                "handler": None,
                "agents": [
                    {"area": area, "subagent_type": f"code-reviewer-{area}"}
                    for area in areas
                ],
            }
    except (OSError, ValueError, AttributeError, TypeError) as error:
        parser.exit(1, f"review dispatch plan: {error}\n")
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
