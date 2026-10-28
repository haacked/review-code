#!/usr/bin/env python3
"""Run recorded findings through the comment quality stages and count words.

Replays handlers/review-finding-quality.md from the preflight gate through
publication with live `claude -p` calls: preflight, composer, wording lint and
one composer repair, final gate, and one composer repair with its recheck, plus
a two-sentence repair for a blocking finding the recheck still rejects. Each
call uses an agent definition from agents/ at --ref as its system prompt, and
the composer's briefing holds briefing/shared-instructions.md at that ref, so
two refs can be compared on the same findings. The routing and contract scripts
always come from the working tree, so --ref cannot replay a ref whose pipeline
differs from the working tree's. Run that ref's own copy of this script instead.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "skills/review-code/scripts"
sys.path.insert(0, str(SCRIPTS / "helpers"))

from lint_loader import load_linter  # noqa: E402
from markdown_fences import walk_fences  # noqa: E402

DEFAULT_FIXTURE = ROOT / "tests/fixtures/finding-comments/pr-113272.json"
# The handler sets no fence width for gate and composer replies. Agents
# sometimes close a four-backtick fence with three, or write a sentence before
# the fence.
FENCED_ARRAY = re.compile(r"`{3,4}json\s*\n(?P<body>.*?)\n`{3,4}", re.S)
LINTER = load_linter()


def words(body: str | None) -> int | None:
    return None if body is None else len(body.split())


def lint_categories(body: str | None) -> list[str] | None:
    """Return the voice lint categories a published body still carries."""
    if body is None:
        return None
    return sorted({warning["category"] for warning in LINTER.lint(body)})


def prose_words(body: str) -> int:
    return sum(
        len(line.split())
        for _, line, kind in walk_fences(body.splitlines())
        if kind == "prose"
    )


def run(*argv: str) -> str:
    return subprocess.run(argv, check=True, capture_output=True, text=True).stdout


def read_source(path: str, ref: str | None) -> str:
    if ref:
        return run("git", "-C", str(ROOT), "show", f"{ref}:{path}")
    return (ROOT / path).read_text(encoding="utf-8")


def load_agent(name: str, ref: str | None) -> tuple[str, str]:
    _, frontmatter, body = read_source(f"agents/{name}.md", ref).split("---", 2)
    return body.strip(), re.search(r"^model:\s*(\S+)", frontmatter, re.M).group(1)


def parse_array(text: str) -> list[Any]:
    text = text.strip()
    match = FENCED_ARRAY.search(text)
    values = json.loads(match.group("body") if match else text)
    if not isinstance(values, list):
        raise ValueError("response is not a JSON array")
    return values


def array(reply: str | None) -> list[Any]:
    """Parse a reply, treating a failed call or a malformed reply as no items."""
    if reply is None:
        return []
    try:
        return parse_array(reply)
    except ValueError as error:
        print(f"warning: {error}", file=sys.stderr)
        return []


def write_json(path: Path, value: Any) -> Path:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    return path


def script(name: str, *args: str) -> dict[str, Any]:
    return json.loads(run(sys.executable, str(SCRIPTS / name), *args))


class Runner:
    def __init__(self, out: Path, ref: str | None):
        self.out = out
        self.ref = ref
        self.cost = 0.0
        self.calls: list[dict[str, Any]] = []

    def agent(
        self, name: str, stage: str, items: list[dict[str, Any]], *context: str
    ) -> str | None:
        input_path = write_json(self.out / f"{stage}-input.json", items)
        prompt = run(
            sys.executable,
            str(SCRIPTS / "build-finding-prompt.py"),
            "--agent",
            name,
            "--input",
            str(input_path),
            *context,
        )
        system, model = load_agent(name, self.ref)
        return self.claude(stage, name, prompt, system, model)

    def claude(
        self, stage: str, agent: str, prompt: str, system: str, model: str
    ) -> str | None:
        """Return the reply text, or None when the call fails.

        The reply also goes to `<stage>-reply.md`, empty on failure.
        """
        env = dict(os.environ)
        env.pop("CLAUDECODE", None)
        command = [
            os.environ.get("CLAUDE_BIN", "claude"),
            "-p",
            prompt,
            "--model",
            model,
            "--system-prompt",
            system,
            "--output-format",
            "json",
            "--tools",
            "Read",
            "--allowedTools",
            "Read",
            "--setting-sources",
            "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config",
            '{"mcpServers":{}}',
            "--no-session-persistence",
        ]
        with tempfile.TemporaryDirectory(prefix="comment-quality-eval-") as workdir:
            completed = subprocess.run(
                command, cwd=workdir, env=env, capture_output=True, text=True
            )
        (self.out / f"{stage}-output.json").write_text(completed.stdout)
        record = {"stage": stage, "agent": agent, "model": model, "ok": False}
        self.calls.append(record)
        reply = None
        if completed.returncode == 0:
            envelope = json.loads(completed.stdout)
            record["cost_usd"] = envelope.get("total_cost_usd") or 0.0
            self.cost += record["cost_usd"]
            reply = envelope.get("result", "")
            record["ok"] = True
        else:
            print(
                f"warning: {stage}: claude exited {completed.returncode}",
                file=sys.stderr,
            )
        (self.out / f"{stage}-reply.md").write_text(reply or "")
        return reply


def contract_input(fixture: dict[str, Any], style: str) -> list[dict[str, Any]]:
    items = []
    for index, case in enumerate(fixture["cases"], 1):
        file, _, line = case["location"].partition(":")
        items.append(
            {
                "id": index,
                "agent": case["agent"],
                "severity": case["severity"],
                "comment_style": style,
                "location": case["location"],
                "file": file,
                "line": int(line.split("-")[0]),
                "side": "RIGHT",
                "confidence": case["confidence"],
                # Fixture cases record the severity the review posted, after
                # finding validation, so a blocking case passed the validator.
                "validator_confirmed": case["severity"] == "blocking",
                "description": case["draft"],
                "proposed_fix": case["proposed_fix"],
                "facts": case["facts"],
            }
        )
    return items


def gate(runner: Runner, stage: str, quality: dict[str, Any], final: bool) -> dict:
    composed = write_json(runner.out / f"{stage}-composed.json", quality)
    items = [{**item, "kind": "finding"} for item in quality["findings"]]
    verdicts = array(runner.agent("comprehension-gate", stage, items))
    path = write_json(runner.out / f"{stage}-verdicts.json", verdicts)
    result = script(
        "finding-comment-contract.py",
        "gate",
        *(["--final"] if final else []),
        str(composed),
        str(path),
    )
    # The composer repairs from the contract's reasons and the gate's unresolved phrases.
    unresolved = {
        v.get("id"): v.get("unresolved") for v in verdicts if isinstance(v, dict)
    }
    for entry in result["rewrites_needed"]:
        entry["unresolved"] = unresolved.get(entry["id"]) or []
    return result


def compose(
    runner: Runner, stage: str, entries: list[dict[str, Any]], context: list[str]
) -> dict:
    """Merge composer bodies into entries and withhold any the composer failed."""
    by_id: dict[Any, list[dict[str, Any]]] = {}
    for response in array(
        runner.agent("code-reviewer-comment", stage, entries, *context)
    ):
        if isinstance(response, dict):
            by_id.setdefault(response.get("id"), []).append(response)
    merged, failed = [], []
    for entry in entries:
        found = by_id.get(entry["id"], [])
        response = found[0] if len(found) == 1 else {}
        if not isinstance(response.get("description"), str) or response.get("error"):
            reason = response.get("error") or "composer returned no unique body"
            failed.append(
                {
                    **entry,
                    "publishable": False,
                    "quality_state": "composition_failed",
                    "reasons": [reason],
                }
            )
            continue
        merged.append(
            {
                **entry,
                "description": response["description"],
                "proposed_fix": response.get("proposed_fix", entry["proposed_fix"]),
            }
        )
    result = script(
        "finding-comment-contract.py",
        "compose",
        str(write_json(runner.out / f"{stage}-merged.json", merged)),
    )
    result["withheld"].extend(failed)
    return result


def lint_repair(
    runner: Runner, quality: dict[str, Any], context: list[str]
) -> dict[str, Any]:
    """Lint every body and send the warned ones to one composer repair, as the handler does."""
    targets_path = runner.out / "lint-repair-input.json"
    result = script(
        "gate-voice-lint.py",
        "--repair-input",
        str(targets_path),
        str(write_json(runner.out / "voice-lint-input.json", quality)),
    )
    write_json(runner.out / "voice-lint-result.json", result)
    if result["error"] or not result["repair_ids"]:
        return quality
    targets = json.loads(targets_path.read_text())
    repaired = {
        item["id"]: item
        for item in compose(runner, "lint-repair", targets, context)["findings"]
    }
    # A failed repair keeps the body it replaced, which passed preflight or composition.
    return {
        **quality,
        "findings": [repaired.get(item["id"], item) for item in quality["findings"]],
    }


def run_pipeline(
    fixture: dict[str, Any], runner: Runner, style: str, context: list[str]
) -> dict[str, Any]:
    validated = script(
        "finding-comment-contract.py",
        "compose",
        str(
            write_json(
                runner.out / "contract-input.json", contract_input(fixture, style)
            )
        ),
    )
    # The gate carries the contract's withheld entries into its own result.
    preflight = gate(runner, "finding-preflight", validated, final=False)
    withheld = list(preflight["withheld"])
    passed = [
        {**item, "publishable": False, "quality_state": "preflight_passed"}
        for item in preflight["findings"]
    ]
    composed = {"findings": [], "withheld": []}
    if preflight["rewrites_needed"]:
        composed = compose(
            runner, "comment-compose", preflight["rewrites_needed"], context
        )
    withheld.extend(composed["withheld"])

    linted = lint_repair(runner, {"findings": passed + composed["findings"]}, context)
    first = gate(runner, "comprehension", {"findings": linted["findings"]}, final=False)
    published = list(first["findings"])
    withheld.extend(first["withheld"])

    def repair(entry: dict[str, Any], stage: str) -> list[dict[str, Any]]:
        """Repair one finding, recheck it, and return what the recheck sends back."""
        repaired = compose(runner, f"comment-repair-{stage}", [entry], context)
        withheld.extend(repaired["withheld"])
        if not repaired["findings"]:
            return []
        recheck = gate(runner, f"comprehension-recheck-{stage}", repaired, final=True)
        published.extend(recheck["findings"])
        withheld.extend(recheck["withheld"])
        return recheck["rewrites_needed"]

    for entry in first["rewrites_needed"]:
        # Only a confirmed blocking finding comes back, for a repair limited to
        # two sentences. The second recheck never sends one back.
        for blocking in repair(entry, str(entry["id"])):
            withheld.extend(repair(blocking, f"blocking-{blocking['id']}"))

    final_path = write_json(
        runner.out / "finding-quality-final.json",
        {"findings": published, "withheld": withheld},
    )
    publication = script("finding-comment-contract.py", "publish", str(final_path))
    write_json(runner.out / "finding-publication.json", publication)
    return publication


def revision(ref: str | None) -> dict[str, Any]:
    if ref:
        return {
            "ref": ref,
            "commit": run("git", "-C", str(ROOT), "rev-parse", ref).strip(),
        }
    changes = run(
        "git", "-C", str(ROOT), "status", "--porcelain", "--", "agents", "skills"
    )
    return {
        "ref": "working tree",
        "commit": run("git", "-C", str(ROOT), "rev-parse", "HEAD").strip(),
        "uncommitted_changes": bool(changes.strip()),
    }


def total(values: list[int | None]) -> int | None:
    present = [value for value in values if value is not None]
    return sum(present) if present else None


def score(fixture: dict[str, Any], publication: dict[str, Any], runner: Runner) -> dict:
    bodies = {item["id"]: item["description"] for item in publication["findings"]}
    withheld = {
        item.get("id"): item.get("quality_state") for item in publication["withheld"]
    }
    cases = []
    for index, case in enumerate(fixture["cases"], 1):
        body = bodies.get(index)
        cases.append(
            {
                "id": index,
                "location": case["location"],
                "severity": case["severity"],
                "words": words(body),
                "prose_words": None if body is None else prose_words(body),
                "before_words": words(case.get("before")),
                "after_words": words(case.get("after")),
                "withheld": withheld.get(index),
                "lint": lint_categories(body),
                "body": body,
            }
        )
    return {
        **revision(runner.ref),
        "fixture": fixture["source"],
        "published": sum(case["words"] is not None for case in cases),
        "withheld": sum(case["words"] is None for case in cases),
        "published_over_gate": sum(
            item.get("quality_state") == "published_over_gate"
            for item in publication["findings"]
        ),
        "words": total([case["words"] for case in cases]) or 0,
        "prose_words": total([case["prose_words"] for case in cases]) or 0,
        "before_words": total([case["before_words"] for case in cases]),
        "after_words": total([case["after_words"] for case in cases]),
        "cost_usd": round(runner.cost, 4),
        "calls": runner.calls,
        "cases": cases,
    }


def table(summary: dict[str, Any]) -> str:
    def cell(value: Any) -> str:
        return "-" if value is None else str(value)

    rows = [
        "| # | Location | Before | After | This run | Lint |",
        "| ---: | --- | ---: | ---: | ---: | --- |",
    ]
    for case in summary["cases"]:
        this_run = (
            cell(case["words"])
            if case["withheld"] is None
            else f"withheld ({case['withheld']})"
        )
        lint = "-" if case["lint"] is None else ", ".join(case["lint"])
        rows.append(
            f"| {case['id']} | `{case['location']}` | {cell(case['before_words'])} | {cell(case['after_words'])} | {this_run} | {lint} |"
        )
    rows.append(
        f"| | Total | {cell(summary['before_words'])} | {cell(summary['after_words'])} | {summary['words']} | |"
    )
    return "\n".join(rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument(
        "--diff", type=Path, required=True, help="the PR diff the composer reads"
    )
    parser.add_argument(
        "--out", type=Path, required=True, help="a new directory for this run"
    )
    parser.add_argument(
        "--ref", help="git ref to read agent definitions from (default: working tree)"
    )
    parser.add_argument("--style", choices=("concise", "detailed"), default="concise")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
    args.out.mkdir(parents=True)
    out = args.out.resolve()
    briefing = out / "briefing.md"
    briefing.write_text(
        f"Review of {fixture['source']} at {fixture['head_sha']}.\n\n"
        + read_source("skills/review-code/briefing/shared-instructions.md", args.ref)
    )
    file_access = out / "file-access.md"
    file_access.write_text(
        "Only the diff is available. Read changed code there; no other source files exist.\n"
    )
    context = [
        "--diff",
        str(args.diff.resolve()),
        "--briefing",
        str(briefing),
        "--file-access",
        str(file_access),
    ]
    runner = Runner(out, args.ref)
    summary = score(fixture, run_pipeline(fixture, runner, args.style, context), runner)
    write_json(out / "summary.json", summary)
    print(table(summary))
    print(
        f"\nPublished {summary['published']} of {len(fixture['cases'])}; "
        f"{summary['prose_words']} prose words; ${summary['cost_usd']:.2f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
