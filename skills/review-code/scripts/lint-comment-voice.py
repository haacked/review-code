#!/usr/bin/env python3
"""Report review-comment style violations without scoring the prose.

Reads text (one or more comment bodies, or a whole review document) and emits
one JSON line per warning, or the literal "[]" when the input is clean. The
rules come from the review-code voice agent (agents/code-reviewer-voice.md):
the checks a regex can perform deterministically so a cheap script can gate
what three LLM passes let through.

Code blocks, inline code, URLs, review-metadata comment blocks, and severity
prefixes are masked before any rule runs: they are structure, not prose.

Warnings are advisory. Nothing here exits nonzero unless --fail-on-warnings is
passed, so a malformed rule or a surprising input can never block a review.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable, TypedDict

# Rules drawn from agents/code-reviewer-voice.md, limited to what a regex can
# judge without reading the surrounding code. Each pattern is prose-only: code,
# URLs, and severity prefixes are masked before these run.
RAW_PATTERNS: dict[str, tuple[str, ...]] = {
    # Reviewer-internal vocabulary. "Sibling" only when it names a test or
    # function (siblings in the tree sense are fine); anchor/corroborate as
    # pipeline bookkeeping. Prefix-anchored attribution labels ("Raised by",
    # "Agents:") stay exempt because the review writes them deliberately for
    # the reader.
    "reviewer_vocabulary": (
        r"\bsiblings?\b(?=[^.]{0,40}\b(?:test|case|function|files?)\b)",
        r"(?<!\*\*)\bcorroborat\w+\b(?!\*\*)",
        r"\banchor(?:s|ed|ing)?\b(?=[^.]{0,40}\b(?:reference|claim|term|permalinks?|finding|point)\b)",
    ),
    # Formal logic register. "Predicate" and "invariant" are fine as nouns for
    # what the code *is* (a predicate function); the violation is using them as
    # proof labels: asserting one "holds" or is "satisfied" without a check.
    "logic_register": (
        r"\bvacuously\b",
        r"\btautolog\w+\b",
        r"\bconjuncts?\b",
        r"\bdisjuncts?\b",
        r"\bbiff\b",
        r"\binvariants?\s+(?:holds?|is|are|remains?|stays?)\s+(?:intact|satisfied|preserved|maintained|true|unchanged|enforced|upheld|respected)\b",
        r"\b(?:holds?|satisfies|satisfied|preserves|preserved)\s+(?:vacuously|the\s+invariants?)\b",
        r"\bpredicates?\s+(?:holds?|is satisfied|are satisfied)\b",
    ),
    # "Pin" as a verb for what a test covers. The regex must not fire on literal
    # version or SHA pinning, which is allowed by the voice agent ("Version and
    # SHA pinning are literal and stay as written").
    "pinning": (
        r"\bpinned by\b",
        r"\bpin down\b",
        r"\bpins? (?:the|that|this|down)\b",
        r"\bpinning (?:the|this|that|down)\b",
        r"\bis(?:n['’]t| not) pinned\b",
        r"\bunpinned\b",
        r"\bnot pinned\b",
        r"\bpinned (?:elsewhere|here|now|already|in)\b",
        r"\bpinned to the (?:behaviour|behavior)\b",
    ),
    # Applying a named shortcut where the behavior belongs. The voice agent
    # bans coined labels ("the withholding boundary"), test-theory categories
    # ("weak positive assertion"), and metaphor-jargon ("load-bearing").
    "labeling": (
        r"\bload-bearing\b",
        r"\bhappy paths?\b",
        r"\bcode smells?\b",
        r"\bthe \w+ (?:window|boundary|hazard|trap|gap|wart) is\b",
        r"\bweak positive assertions?\b",
        r"\bweak negative assertions?\b",
        r"\btautological tests?\b",
        r"\bthe contract isn['’]t pinned\b",
        r"\bweak asserts?\b",
    ),
    # Filler, hype, and chatbot closers that inflate a finding without content.
    "filler": (
        r"\blet(?:'|’)s (?:dive in|dive into|explore|break this down)\b",
        r"\bhere(?:'|’)s what you need to know\b",
        r"\bit is (?:important|worth) to note\b",
        r"\bin order to\b",
        r"\bdue to the fact that\b",
        r"\bat this point in time\b",
        r"\bin the event that\b",
        r"\bi hope this helps\b",
        r"\blet me know\b",
        r"\bgreat work\b",
        r"\bnice approach\b",
        r"\bawesome pr\b",
    ),
    "hype": (
        r"\b(?:robust|seamless|powerful|pivotal|groundbreaking|revolutionary)\b",
        r"\b(?:world-class|cutting-edge|effortless|game-changing|best-in-class)\b",
        r"\bcomprehensive\b",
        r"\bcritical\b",
        r"\bmeaningful state change\b",
    ),
    # AI vocabulary clichés. The voice agent lists these with the same words.
    "ai_vocabulary": (
        r"\bleverag(?:e|es|ed|ing)\b",
        r"\butiliz(?:e|es|ed|ing|ation)\b",
        r"\bfacilitat(?:e|es|ed|ing)\b",
        r"\bnavigat(?:e|es|ed|ing)\b",
        r"\bensure\b",
        r"\bdelve\b",
    ),
    # Named shorthand for a category where the behavior belongs, per the voice
    # agent's "no coined labels" rule. Anchored to a small set of nouns that the
    # voice agent itself calls out; broader noun lists drown in false positives.
    "coined_label": (
        r"\bthe \w+ (?:window|boundary|hazard) is\b",
        r"\bthe (?:window|boundary|hazard) collapses\b",
    ),
    # Pipeline provenance that leaked into the body. The voice agent strips
    # these when rewriting; flagging them upstream lets the drafting pass drop
    # them before the voice agent ever sees them. Author-attribution labels that
    # the review itself writes for the reader ("Raised by: … (corroborated)")
    # are structure, not leaks, and stay exempt.
    "provenance_leak": (r"\*\s*\((?:corroborat\w+|flagged|disputed)[^*]*\)\*",),
    # Verdict-first openers. The voice agent bans opening with a label or
    # adjective stack ("This is a real upgrade-window risk", "Sound and
    # proportionate"); these patterns catch the common shapes.
    "verdict_opener": (
        r"^\s*This is a (?:real|genuine|significant|serious|major|critical|subtle|classic|common|textbook)\b",
        r"^\s*This (?:will|would) (?:likely|probably|potentially|silently|quietly|easily)\b",
        r"^\s*Sound and\b",
        r"^\s*Proportionate to the goal\b",
        r"^\s*Direct, well-scoped\b",
        r"^\s*In good shape\b",
        r"^\s*The new machinery is\b",
    ),
    # Pseudo-headers the voice agent strips. These read as labels where the
    # sentence should just say the thing.
    "pseudo_header": (
        r"\*\*Issue\*\*:",
        r"\*\*Impact\*\*:",
        r"\*\*Recommendation\*\*:",
        r"\*\*Fix\*\*:",
        r"\*\*Problem\*\*:",
        r"\*\*Solution\*\*:",
        r"\*\*Vulnerability\*\*:",
        r"\*\*Problem\*\* \S",
        r"\*\*Solution\*\* \S",
    ),
    # Hedging and throat-clearing that inflate the body.
    "hedging": (
        r"\bjust a thought,? but\b",
        r"\bi might be wrong,? but\b",
        r"\bto be honest\b",
        r"\bto be fair\b",
        r"\bi['’]d argue that\b",
        r"\bit seems like\b",
        r"\bit appears that\b",
        r"\bkind of\b",
        r"\bsort of\b",
    ),
    # Signposting and repeated-summary patterns that pad a body.
    "signposting": (
        r"\bfirst,?\s+.{0,40}\bsecond,?\s+.{0,40}\bthird,?\s+",
        r"\bin summary\b",
        r"\bto summarize\b",
        r"\bin conclusion\b",
        r"\bas (?:we|i) (?:mentioned|discussed|saw|noted) (?:above|earlier|before)\b",
        r"\bobviously\b",
        r"\bclearly,?\s+(?:this|the|it)\b",
    ),
    # Compound-framework register. Words like "orthogonal" label code instead
    # of describing it. "Idiomatic", "canonical", "ergonomic", "elegant", and
    # "seamless" fire too often on prose the repo itself treats as fine, so the
    # linter stays silent on them until a sharper discriminator exists.
    "framework_jargon": (
        r"\borthogonally?\b",
        r"\bfirst-class\b",
    ),
}

PATTERNS: dict[str, tuple[re.Pattern[str], ...]] = {
    category: tuple(re.compile(pattern, re.I) for pattern in patterns)
    for category, patterns in RAW_PATTERNS.items()
}

FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
METADATA_COMMENT = re.compile(r"<!--\s*review-metadata(?:\s[^-]*)?.*?-->", re.S)
# Structural Markdown that should never be read as prose: section headers,
# table rows and separators, horizontal rules, and boilerplate labels that name
# a finding's position rather than argue about code.
HEADING = re.compile(r"^ {0,3}#{1,6}\s+")
TABLE_ROW = re.compile(r"^\s*\|.*\|\s*$")
HR = re.compile(r"^\s*(?:[-*_]\s*){3,}$")
LABEL_LINE = re.compile(
    r"^\s*(?:\*\*)?(?:Location|Found by|Raised by|Resolution|Agents?|Severity|"
    r"Confidence|Status|Assessment|Source|Thread|Review scope|Fix summary)\s*"
    r"(?:\*\*)?\s*:(?:\s|$)",
    re.I,
)
INLINE_CODE = re.compile(r"`[^`]*`")
URL = re.compile(r"https?://[^\s)>]+")
WORD = re.compile(r"[A-Za-z0-9][A-Za-z0-9'’/-]*")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")

SEVERITY_TOKENS = r"blocking|suggestion|question|nit"
# Bold and backticks nest either way round in real reviews, so accept any
# run of them on both sides rather than one fixed order.
SEVERITY_WRAP = r"(?:\*\*|`)*"
# The separator is a colon or an em/en dash; reviews use both. The ASCII hyphen
# is deliberately excluded, since it would swallow a sentence opening
# "Nit-picking aside". Without the dash, the structural dash in a title like
# **`question` — …** stays in the prose and the dash rule reports on it.
SEVERITY_PREFIX = re.compile(
    rf"^\s*{SEVERITY_WRAP}(?:{SEVERITY_TOKENS}){SEVERITY_WRAP}\s*(?::|\s*[—–])",
    re.I,
)

# Categories that are only worth reporting once per line, so a body with three
# em dashes doesn't triple-report.
CAPPED_CATEGORIES = {"dash"}


# How much of the offending line to quote back. Both pipeline consumers show
# this excerpt: the gate hands it to the voice agent on a bounce, the narrative
# linter writes it into the review, and they should agree.
TEXT_EXCERPT_CHARS = 160


class LintWarning(TypedDict):
    line: int
    category: str
    message: str
    text: str


def trim_warning(item: LintWarning, **extra) -> dict:
    """Render one warning for a consumer, with the quoted line bounded."""
    return {
        **extra,
        "line": item["line"],
        "category": item["category"],
        "message": item["message"],
        "text": item["text"][:TEXT_EXCERPT_CHARS],
    }


def prose_lines(text: str) -> Iterable[tuple[int, str, str]]:
    """Yield (line_number, original_line, prose) with code and metadata masked."""
    # Blank whole-document review-metadata blocks before line iteration. A
    # block comment that spans lines would otherwise survive per-line masking.
    # Newlines are preserved so reported line numbers still point at the file.
    text = METADATA_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)

    fence = ""
    for line_number, line in enumerate(text.splitlines(), start=1):
        marker = FENCE.match(line)
        token = marker.group(1) if marker else ""
        if fence:
            if marker and token.startswith(fence) and not line[marker.end() :].strip():
                fence = ""
            continue
        if token:
            fence = token
            continue

        if (
            HEADING.match(line)
            or TABLE_ROW.match(line)
            or HR.match(line)
            or LABEL_LINE.match(line)
        ):
            continue

        prose = URL.sub("", INLINE_CODE.sub("", strip_severity_prefix(line)))
        yield line_number, line, prose


def strip_severity_prefix(prose: str) -> str:
    """Drop a leading severity prefix so rules don't flag the prefix itself."""
    return SEVERITY_PREFIX.sub("", prose, count=1)


def warning(line: int, category: str, message: str, text: str) -> LintWarning:
    return {
        "line": line,
        "category": category,
        "message": message,
        "text": text.strip(),
    }


def lint(text: str) -> list[LintWarning]:
    warnings: list[LintWarning] = []

    for line_number, original, raw_prose in prose_lines(text):
        prose = raw_prose.strip()
        if not prose:
            continue

        for category, patterns in PATTERNS.items():
            if any(pattern.search(raw_prose) for pattern in patterns):
                warnings.append(
                    warning(
                        line_number,
                        category,
                        f"Possible {category.replace('_', ' ')}; use concrete, direct wording.",
                        original,
                    )
                )

        if "—" in raw_prose or "–" in raw_prose:
            warnings.append(
                warning(
                    line_number,
                    "dash",
                    "Restructure the sentence without an em dash or en dash.",
                    original,
                )
            )

    # A long-sentence check belongs to strict technical writing, not review
    # comments. The voice agent's own length guidance is shaped by finding
    # severity, not by a fixed word count, so the linter stays silent here.

    return warnings


def render_jsonl(warnings: list[LintWarning]) -> str:
    return "\n".join(json.dumps(item) for item in warnings)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "files",
        nargs="*",
        help="Files to lint; read stdin when omitted or when the path is '-'",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        metavar="<n>",
        help="Keep at most n warnings per category and note how many were suppressed "
        "(0 keeps them all)",
    )
    parser.add_argument(
        "--fail-on-warnings",
        action="store_true",
        help="Exit 1 when warnings exist; warnings do not fail by default",
    )
    return parser.parse_args()


def cap_warnings(
    warnings: list[LintWarning], limit: int
) -> tuple[list[LintWarning], dict[str, int]]:
    if limit <= 0:
        return warnings, {}
    kept: list[LintWarning] = []
    suppressed: dict[str, int] = {}
    seen: dict[str, int] = {}
    for item in warnings:
        category = item["category"]
        count = seen.get(category, 0)
        if count < limit:
            kept.append(item)
            seen[category] = count + 1
        else:
            suppressed[category] = suppressed.get(category, 0) + 1
    return kept, suppressed


def main() -> int:
    args = parse_args()
    inputs = args.files or ["-"]

    all_warnings: list[LintWarning] = []
    for name in inputs:
        text = (
            sys.stdin.read() if name == "-" else Path(name).read_text(encoding="utf-8")
        )
        all_warnings.extend(lint(text))

    all_warnings.sort(key=lambda item: (item["line"], item["category"]))
    kept, suppressed = cap_warnings(all_warnings, args.limit)
    if not kept and not suppressed:
        print("[]")
        return 0
    rendered = render_jsonl(kept)
    for category, count in sorted(suppressed.items()):
        if rendered:
            rendered += "\n"
        rendered += json.dumps(
            {
                "note": f"Further {category} warning(s) suppressed by --limit.",
                "suppressed": count,
            }
        )
    print(rendered)

    has_warnings = bool(all_warnings)
    return 1 if args.fail_on_warnings and has_warnings else 0


if __name__ == "__main__":
    raise SystemExit(main())
