#!/usr/bin/env python3
"""Render Claude Markdown agent definitions as Codex TOML agents.

Reads the reviewers under agents/ and writes one TOML per agent into the
staging directory bin/install-codex.sh links into ~/.codex/agents. Model
aliases come from codex/model-tiers.conf at the repo root.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

MANAGED_HEADER = "# Managed by bin/install-codex.sh from the review-code repo.\n"


def load_model_tiers() -> dict[str, tuple[str, str]]:
    """Read codex/model-tiers.conf into a claude-model -> (codex-model, effort) map."""
    config_path = pathlib.Path(__file__).parent.parent / "codex" / "model-tiers.conf"
    model_map: dict[str, tuple[str, str]] = {}
    for line in config_path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        try:
            _tier, claude_model, codex_model, effort = line.split("|")
        except ValueError:
            raise ValueError(f"{config_path}: malformed row {line!r}") from None
        model_map[claude_model] = (codex_model, effort)
    return model_map


def parse_agent(path: pathlib.Path) -> tuple[dict[str, str], str]:
    text = path.read_text()
    match = re.match(r"\A---\n(.*?)\n---\n?(.*)\Z", text, re.DOTALL)
    if not match:
        raise ValueError(f"{path}: missing YAML frontmatter")

    metadata: dict[str, str] = {}
    for line in match.group(1).splitlines():
        # Indented lines belong to a nested block (e.g. `metadata:`); the
        # schema Codex cares about is flat, so ignore them.
        if line[:1].isspace():
            continue
        key, separator, value = line.partition(":")
        if not separator or key not in {"name", "description", "model"}:
            continue
        value = value.strip()
        if value.startswith("'"):
            raise ValueError(f"{path}: single-quoted frontmatter is not supported")
        if value.startswith('"') and value.endswith('"'):
            value = json.loads(value)
        metadata[key] = value

    for required in ("name", "description"):
        if not metadata.get(required):
            raise ValueError(f"{path}: missing {required}")
    return metadata, match.group(2).strip() + "\n"


def render(path: pathlib.Path, model_map: dict[str, tuple[str, str]]) -> str:
    metadata, body = parse_agent(path)
    lines = [
        MANAGED_HEADER.rstrip(),
        f"name = {json.dumps(metadata['name'])}",
        f"description = {json.dumps(metadata['description'])}",
    ]
    model = metadata.get("model", "inherit")
    if model != "inherit":
        if model not in model_map:
            raise ValueError(
                f"{path}: unknown model {model!r}; add a row for it to codex/model-tiers.conf"
            )
        codex_model, effort = model_map[model]
        lines.extend(
            [
                f"model = {json.dumps(codex_model)}",
                f"model_reasoning_effort = {json.dumps(effort)}",
            ]
        )
    lines.append(f"developer_instructions = {json.dumps(body)}")
    return "\n".join(lines) + "\n"


def main() -> int:
    """Render every agents/*.md into OUTPUT_DIR and prune managed TOMLs we no longer emit."""
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} SOURCE_DIR OUTPUT_DIR", file=sys.stderr)
        return 2

    source_dir = pathlib.Path(sys.argv[1])
    output_dir = pathlib.Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)
    expected: set[pathlib.Path] = set()
    model_map = load_model_tiers()

    for source in sorted(source_dir.glob("*.md")):
        destination = output_dir / f"{source.stem}.toml"
        destination.write_text(render(source, model_map))
        expected.add(destination)

    for destination in output_dir.glob("*.toml"):
        if destination not in expected and destination.read_text().startswith(
            MANAGED_HEADER
        ):
            destination.unlink()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
