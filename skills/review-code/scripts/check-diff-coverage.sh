#!/usr/bin/env bash
set -euo pipefail

# check-diff-coverage.sh - Check how much of the diff each agent actually read.
#
# Agents receive their diff as a path, and the prompt tells them how many lines
# it has so they can tell whether Read truncated it. That guard is advisory: it
# only helps an agent that uses Read and compares, and most agents page the diff
# with `sed` through Bash instead, where it never applies. An agent that stops
# early reviews less than it was asked to and says nothing, which is the failure
# this skill's whole design is trying to avoid.
#
# This reads a review session's subagent transcripts and reports, per agent, the
# union of the diff line ranges it pulled in via either Read or `sed -n 'A,Bp'`.
#
# A chunked review hands different agents different patch files (chunk-0.patch,
# chunk-1.patch, ...) with different lengths, and an area-scoped agent gets
# diff-frontend.patch rather than the full diff.patch. This script sizes each
# agent against the file it actually read, taken from its own tool calls, so a
# complete read of a short chunk does not compute as a fraction of a long one
# and a truncated read of a long chunk cannot wrap past 100%. --diff-lines is
# the denominator only when no patch path appears in the transcript.
#
# Usage:
#   check-diff-coverage.sh --diff-lines <n> [options]
#
# Options:
#   --dir <path>      Transcript root (default: ~/.claude/projects)
#   --session <uuid>  Session whose subagents to inspect
#                     (default: $CLAUDE_CODE_SESSION_ID)
#   --diff-lines <n>  Lines in the full diff; the fallback denominator when a
#                     transcript names no patch file
#   --min-pct <n>     Coverage below this lands the agent in `below_threshold`
#                     (default: 90)
#   --json            Emit machine-readable JSON instead of a table
#
# Always exits 0 when it can read the transcripts. Short coverage is a result,
# not an error; the caller decides what to do about it.

DIR="${HOME}/.claude/projects"
SESSION="${CLAUDE_CODE_SESSION_ID:-}"
DIFF_LINES=""
MIN_PCT="90"
AS_JSON="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            DIR="${2:-}"
            shift 2
            ;;
        --session)
            SESSION="${2:-}"
            shift 2
            ;;
        --diff-lines)
            DIFF_LINES="${2:-}"
            shift 2
            ;;
        --min-pct)
            MIN_PCT="${2:-90}"
            shift 2
            ;;
        --json)
            AS_JSON="true"
            shift
            ;;
        -h | --help)
            sed -n '4,38p' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${SESSION}" ]]; then
    echo "ERROR: --session is required (CLAUDE_CODE_SESSION_ID is unset)" >&2
    exit 1
fi

if [[ -z "${DIFF_LINES}" ]]; then
    echo "ERROR: --diff-lines is required" >&2
    exit 1
fi

DIR="${DIR}" SESSION="${SESSION}" DIFF_LINES="${DIFF_LINES}" MIN_PCT="${MIN_PCT}" \
    AS_JSON="${AS_JSON}" python3 - << 'PYTHON'
import glob, json, os, re, sys

ROOT = os.environ["DIR"]
SESSION = os.environ["SESSION"]
TOTAL = int(os.environ["DIFF_LINES"])
MIN_PCT = int(os.environ["MIN_PCT"])
AS_JSON = os.environ["AS_JSON"] == "true"

# `sed -n '10,20p'`, in either quoting style.
SED = re.compile(r"""sed -n\s+['"](\d+),(\d+)p['"]""")

subdirs = glob.glob(os.path.join(ROOT, "*", SESSION, "subagents"))
if not subdirs:
    print(f"No subagent transcripts for session {SESSION} under {ROOT}", file=sys.stderr)
    sys.exit(1)


def merge(intervals):
    """Union of line ranges, so re-reads are not counted twice.

    Each interval carries [start, end, patch]; only the range is coalesced, so
    sort on the range alone (the path can be None and must not be compared).
    """
    out = []
    for a, b, _ in sorted(intervals, key=lambda iv: (iv[0], iv[1])):
        if out and a <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


# Line counts are read many times per transcript (once per Read/sed call, all
# against the same patch), so cache by path. A missing/unreadable file caches
# None, which routes that agent to the --diff-lines fallback.
_line_counts = {}


def line_count(path):
    if path not in _line_counts:
        try:
            with open(path, "rb") as fh:
                _line_counts[path] = sum(1 for _ in fh)
        except OSError:
            _line_counts[path] = None
    return _line_counts[path]


def target_path(cmd, sed_match):
    """The patch file a sed range applied to, or None when it can't be told.

    Scans the tokens after the range expression for the patch path, skipping a
    redirect (`sed -n 'A,Bp' in.patch > out`) and flags. The path is almost
    always the next token; the scan just avoids crediting a redirect target.
    """
    tail = cmd[sed_match.end():]
    skip_next = False
    for token in tail.split():
        t = token.strip("\"'")
        if skip_next:
            skip_next = False
            continue
        if t in (">", ">>"):
            skip_next = True
            continue
        if t.startswith((">", "-")):
            continue
        return t if t.endswith(".patch") else None
    return None


rows = []
for subdir in subdirs:
    for f in sorted(glob.glob(os.path.join(subdir, "*.jsonl"))):
        meta = f[:-6] + ".meta.json"
        if not os.path.exists(meta):
            continue
        try:
            atype = json.load(open(meta)).get("agentType") or ""
        except ValueError:
            continue
        if not atype.startswith("code-reviewer-"):
            continue

        # Each interval carries the patch it came from, so the denominator can
        # be settled per agent after the transcript is read; clamping waits
        # until then.
        intervals, how = [], set()
        for line in open(f, errors="ignore"):
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            content = (rec.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                inp = block.get("input") or {}
                if block.get("name") == "Read" and inp.get("file_path", "").endswith(".patch"):
                    p = inp.get("file_path")
                    off = inp.get("offset") or 1
                    lim = inp.get("limit") or 2000
                    intervals.append([off, off + lim - 1, p])
                    how.add("Read")
                elif block.get("name") == "Bash":
                    cmd = inp.get("command", "")
                    if ".patch" not in cmd:
                        continue
                    for m in SED.finditer(cmd):
                        intervals.append([int(m.group(1)), int(m.group(2)), target_path(cmd, m)])
                        how.add("sed")

        # Denominator: the line count of the patch the agent read most, else
        # the --diff-lines fallback when no path could be resolved. An agent
        # with a mixed transcript (read from two patch files) is anomalous;
        # sizing against its dominant file keeps that case from flipping the
        # outliers this script exists to catch.
        lines_by_path = {}
        for a, b, p in intervals:
            if p and line_count(p) is not None:
                lines_by_path[p] = lines_by_path.get(p, 0) + (b - a + 1)
        diff_path = max(lines_by_path, key=lines_by_path.get, default=None)
        total = line_count(diff_path) if diff_path else TOTAL

        merged = [[a, min(b, total)] for a, b in merge(intervals) if a <= min(b, total)]
        covered = sum(b - a + 1 for a, b in merged)
        gaps = [[merged[i][1] + 1, merged[i + 1][0] - 1] for i in range(len(merged) - 1)]
        if merged and merged[0][0] > 1:
            gaps.insert(0, [1, merged[0][0] - 1])
        if merged and merged[-1][1] < total:
            gaps.append([merged[-1][1] + 1, total])
        rows.append({"agent": atype, "diff_path": diff_path, "covered": covered, "total": total,
                     "pct": round(100 * covered / total) if total else 0,
                     "unread_ranges": gaps, "method": "+".join(sorted(how)) or "none"})

if not rows:
    print(f"No reviewer subagents in session {SESSION}", file=sys.stderr)
    sys.exit(1)

rows.sort(key=lambda r: r["pct"])

below = [r for r in rows if r["pct"] < MIN_PCT]

if AS_JSON:
    print(json.dumps({"session": SESSION, "diff_lines": TOTAL, "min_pct": MIN_PCT,
                      "agents": rows, "below_threshold": below}, indent=2))
    sys.exit(0)

def patch_label(r):
    return os.path.basename(r["diff_path"]) if r["diff_path"] else "(full diff)"


print(f"{len(rows)} reviewer agents\n")
print(f"{'agent':<32} {'diff':<22} {'covered':>14} {'pct':>5}  {'read via':<10}")
for r in rows:
    print(f"{r['agent']:<32} {patch_label(r):<22} {r['covered']:>6,}/{r['total']:<7,} "
          f"{r['pct']:>4}%  {r['method']:<10}")

if below:
    print(f"\nBelow {MIN_PCT}% and worth re-dispatching:")
    for r in below:
        rng = ", ".join(f"{a}-{b}" for a, b in r["unread_ranges"][:5])
        print(f"  {r['agent']} ({patch_label(r)}): unread {rng}")
    print("\nMap those ranges to files with:")
    print("  grep -n '^diff --git' <diff patch>")
else:
    print(f"\nEvery agent read at least {MIN_PCT}% of its diff.")
PYTHON
