#!/usr/bin/env python3
"""Read or update one metadata block outside Markdown fences."""

import argparse
import os
from pathlib import Path
import re
import tempfile

from markdown_fences import walk_fences


FIELDS = {"review_commit", "reviewed_at", "review_mode", "delta_from"}


def metadata_span(document):
    lines = document.splitlines(keepends=True)
    spans = []
    start = None
    for index, line, kind in walk_fences(lines):
        if kind != "prose":
            continue
        if re.fullmatch(r"<!--[ \t]*review-metadata[ \t]*", line.rstrip("\r\n")):
            if start is not None:
                raise ValueError("unclosed review metadata block")
            start = index
        elif start is not None and line.strip() == "-->":
            spans.append((start, index))
            start = None
    if start is not None:
        raise ValueError("unclosed review metadata block")
    if len(spans) > 1:
        raise ValueError("multiple review metadata blocks")
    return lines, spans[0] if spans else None


def read_field(document, key):
    lines, span = metadata_span(document)
    if span is None:
        return ""
    first, last = span
    values = [
        line.partition(":")[2].strip()
        for line in lines[first + 1 : last]
        if line.startswith(f"{key}:")
    ]
    if len(values) > 1:
        raise ValueError(f"duplicate metadata field: {key}")
    return values[0] if values else ""


def update_document(document, values):
    lines, span = metadata_span(document)
    if span is None:
        header = "<!-- review-metadata\n"
        header += "".join(f"{key}: {value}\n" for key, value in values.items())
        return header + "-->\n\n" + document

    first, last = span
    newline = "\r\n" if lines[first].endswith("\r\n") else "\n"
    output = []
    seen = set()
    for line in lines[first + 1 : last]:
        field = re.match(r"^([a-z_]+):", line)
        key = field.group(1) if field else None
        if key == "delta_from" and values["review_mode"] == "full":
            continue
        if key in values:
            if key not in seen:
                output.append(f"{key}: {values[key]}{newline}")
                seen.add(key)
        else:
            output.append(line)
    output.extend(
        f"{key}: {value}{newline}" for key, value in values.items() if key not in seen
    )
    return "".join(lines[: first + 1] + output + lines[last:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--set", action="append", default=[], dest="assignments")
    parser.add_argument("--get", choices=sorted(FIELDS), dest="read_key")
    args = parser.parse_args()
    temporary = None
    try:
        if args.read_key:
            if args.assignments:
                raise ValueError("--get and --set cannot be combined")
            print(read_field(args.file.read_text(), args.read_key))
            return
        values = {}
        for assignment in args.assignments:
            key, separator, value = assignment.partition("=")
            if key not in FIELDS:
                raise ValueError(f"unsupported metadata field: {key}")
            if (
                not separator
                or not value.strip()
                or any(c in value for c in "\r\n\x00")
            ):
                raise ValueError(f"{key} must have a nonempty single-line value")
            if key in values:
                raise ValueError(f"duplicate assignment: {key}")
            values[key] = value
        if not values.get("reviewed_at") or values.get("review_mode") not in {
            "full",
            "delta",
        }:
            raise ValueError("reviewed_at and review_mode (full or delta) are required")
        if values["review_mode"] == "full":
            values.pop("delta_from", None)
        target = args.file.resolve(strict=True)
        original = target.read_bytes()
        updated = update_document(original.decode(), values).encode()
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(updated)
        temporary.chmod(target.stat().st_mode)
        if target.read_bytes() != original:
            raise ValueError("review changed while updating metadata")
        os.replace(temporary, target)
        temporary = None
    except (OSError, ValueError) as error:
        parser.exit(1, f"review metadata: {error}\n")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
