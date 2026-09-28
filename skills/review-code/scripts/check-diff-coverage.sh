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
# agent against the on-disk line count of the patch it actually named in its
# own tool calls, so a complete read of a short chunk does not compute as a
# fraction of a long one and a truncated read of a long chunk cannot wrap past
# 100%. A read that names no literal .patch at all (a $VAR reference) is
# invisible to this audit — the agent reports 0% and lands in below_threshold
# for re-dispatch, which is the safe direction. When a named patch no longer
# exists on disk (a swept artifacts dir), there is no way to tell a short
# chunk from the full diff, so --diff-lines is the denominator there.
#
# An agent can also review by reading the changed files in the checkout. With
# --repo-dir, a Read or `sed -n 'A,Bp'` of a changed file under that directory
# credits the patch lines that hold the new side of its hunks, plus the file's
# header lines. Removed lines stay unread, because the checkout does not have
# them. The patch the agent named maps files to patch lines, or --diff-file
# when it named none. Omit --repo-dir when the checkout does not hold the
# diff's new side, as in a review from a different branch of the same repo.
#
# Usage:
#   check-diff-coverage.sh --diff-lines <n> [options]
#
# Options:
#   --dir <path>        Transcript root (default: ~/.claude/projects)
#   --session <uuid>    Session whose subagents to inspect
#                       (default: $CLAUDE_CODE_SESSION_ID)
#   --diff-lines <n>    Lines in the full diff; the fallback denominator when a
#                       transcript names no patch the script can count
#   --diff-file <path>  The full diff, used for an agent that named no patch
#   --repo-dir <path>   Checkout whose changed files count as reads of the diff
#   --min-pct <n>       Coverage below this lands the agent in `below_threshold`
#                       (default: 90)
#   --json              Emit machine-readable JSON instead of a table
#
# Always exits 0 when it can read the transcripts. Short coverage is a result,
# not an error; the caller decides what to do about it.

DIR="${HOME}/.claude/projects"
SESSION="${CLAUDE_CODE_SESSION_ID:-}"
DIFF_LINES=""
DIFF_FILE=""
REPO_DIR=""
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
        --diff-file)
            DIFF_FILE="${2:-}"
            shift 2
            ;;
        --repo-dir)
            REPO_DIR="${2:-}"
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
            sed -n '4,49p' "$0" | sed -E 's/^# ?//'
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

DIR="${DIR}" SESSION="${SESSION}" DIFF_LINES="${DIFF_LINES}" DIFF_FILE="${DIFF_FILE}" \
    REPO_DIR="${REPO_DIR}" MIN_PCT="${MIN_PCT}" AS_JSON="${AS_JSON}" python3 - << 'PYTHON'
import codecs, glob, json, os, re, sys

ROOT = os.environ["DIR"]
SESSION = os.environ["SESSION"]
TOTAL = int(os.environ["DIFF_LINES"])
DIFF_FILE = os.environ["DIFF_FILE"] or None
REPO_DIR = os.path.normpath(os.environ["REPO_DIR"]) if os.environ["REPO_DIR"] else None
MIN_PCT = int(os.environ["MIN_PCT"])
AS_JSON = os.environ["AS_JSON"] == "true"

# `sed -n '10,20p'`, quoted either way or not at all.
SED = re.compile(r"""sed -n\s+['"]?(\d+),(\d+)p['"]?""")
# The same, with the file it prints: `sed -n '10,20p' docs/a.md`. A redirect, a
# `--` or a `$VAR` after the range is not a file name.
SED_FILE = re.compile(r"""sed -n\s+['"]?(\d+),(\d+)p['"]?\s+(["']?)([^\s"';|&<>()$-][^\s"';|&<>()]*)\3""")
# Subagents named code-reviewer-* that compose or polish comments and never read the diff.
NOT_REVIEWERS = {"code-reviewer-comment", "code-reviewer-voice"}
HUNK = re.compile(r"@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")

subdirs = glob.glob(os.path.join(ROOT, "*", SESSION, "subagents"))
if not subdirs:
    print(f"No subagent transcripts for session {SESSION} under {ROOT}", file=sys.stderr)
    sys.exit(1)


def merge(intervals):
    """Union of line ranges, so re-reads are not counted twice."""
    out = []
    for a, b in sorted(intervals):
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


# The patch path a .patch-containing command points at, when it is a literal
# path. Anything else (a $VAR, a redirect target, a piped read) returns None;
# a Bash command with no literal .patch is skipped entirely upstream, so its
# sed ranges never count toward coverage.
PATCH_PATH = re.compile(r"(\S+\.patch)\b")


def patch_path(text):
    """The literal .patch path in a tool call, or None when there isn't one."""
    m = PATCH_PATH.search(text or "")
    return m.group(1).strip("\"'") if m else None


_patch_maps = {}


def new_side_path(line):
    """The path in a `+++` header, or None for a deleted file.

    Git ends a path that contains a space with a tab, and quotes a path with
    other unusual characters using C escapes.
    """
    raw = line[4:].rstrip("\n").rstrip("\t")
    if len(raw) > 1 and raw[0] == raw[-1] == '"':
        raw = codecs.escape_decode(raw[1:-1])[0].decode("utf-8", "replace")
    return raw[2:] if raw.startswith("b/") else None


def patch_map(path):
    """For each changed file in a patch, the sections that hold it.

    Each section has its header lines and a new line -> patch line map. A file
    can have two sections when a local review joins the staged and unstaged
    diffs. Hunk line counts decide where a hunk ends, so a removed line that
    starts with `--` is not mistaken for a file header.
    """
    if path not in _patch_maps:
        files, section = {}, None
        old_left = new_left = new_no = 0
        try:
            # Split only at \n so that patch line numbers match sed and wc.
            with open(path, errors="ignore", newline="\n") as fh:
                for n, line in enumerate(fh, 1):
                    if old_left > 0 or new_left > 0:
                        kind = line[:1]
                        if kind == "-":
                            old_left -= 1
                        elif kind == "\\":
                            section["headers"].append(n)
                        else:
                            section["lines"][new_no] = n
                            new_no += 1
                            new_left -= 1
                            if kind != "+":
                                old_left -= 1
                        continue
                    if line.startswith("diff --git "):
                        section = {"headers": [], "lines": {}}
                    if section is None:
                        continue
                    section["headers"].append(n)
                    if line.startswith("+++ ") and (new_path := new_side_path(line)):
                        files.setdefault(new_path, []).append(section)
                    m = HUNK.match(line)
                    if m:
                        old_left = int(m.group(1)) if m.group(1) is not None else 1
                        new_no = int(m.group(2))
                        new_left = int(m.group(3)) if m.group(3) is not None else 1
        except OSError:
            files = {}
        _patch_maps[path] = files
    return _patch_maps[path]


def repo_relative(path, command=""):
    """The path of a file under --repo-dir relative to it, or None.

    A relative path counts only when the same command changes into --repo-dir.
    """
    if not REPO_DIR or not path:
        return None
    if os.path.isabs(path):
        for file, repo in ((os.path.normpath(path), REPO_DIR),
                           (os.path.realpath(path), os.path.realpath(REPO_DIR))):
            rel = os.path.relpath(file, repo)
            if rel != ".." and not rel.startswith("../"):
                return rel
        return None
    cd_repo = r"""(^\s*|[;&|(]\s*)cd\s+["']?""" + re.escape(REPO_DIR) + r"""/?["']?(\s|;|&|\)|$)"""
    return os.path.normpath(path) if re.search(cd_repo, command, re.M) else None


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
        if not atype.startswith("code-reviewer-") or atype in NOT_REVIEWERS:
            continue

        intervals, how, paths = [], set(), set()
        file_reads = []  # (path relative to --repo-dir, first line, last line)
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
                if block.get("name") == "Read":
                    fp = inp.get("file_path", "")
                    off = inp.get("offset") or 1
                    lim = inp.get("limit") or 2000
                    if fp.endswith(".patch"):
                        intervals.append([off, off + lim - 1])
                        paths.add(fp)
                        how.add("Read")
                    elif rel := repo_relative(fp):
                        file_reads.append((rel, off, off + lim - 1))
                elif block.get("name") == "Bash":
                    cmd = inp.get("command", "")
                    other_file_seds = set()
                    for m in SED_FILE.finditer(cmd):
                        target = m.group(4)
                        if target.endswith(".patch"):
                            continue
                        other_file_seds.add(m.start())
                        if rel := repo_relative(target, cmd):
                            file_reads.append((rel, int(m.group(1)), int(m.group(2))))
                    if ".patch" not in cmd:
                        continue
                    paths.add(patch_path(cmd))
                    for m in SED.finditer(cmd):
                        if m.start() in other_file_seds:
                            continue
                        intervals.append([int(m.group(1)), int(m.group(2))])
                        how.add("sed")

        # Denominator. Best case, the agent named a patch we can count on disk:
        # that is its chunk or scoped diff, the whole point of this exercise.
        # A Read with no explicit limit assumes 2000 lines even when its file
        # is shorter, so the on-disk count is the truth and coverage is clamped
        # to it above. With no countable path (a $VAR, a swept artifacts dir),
        # there is no way to tell a short chunk from the full diff, so fall
        # back to --diff-lines; that caller-supplied count is the only honest
        # total left.
        named = [p for p in paths if p]
        counted = [(line_count(p), p) for p in named if line_count(p) is not None]
        # diff_path must come from the same max() as total. Picking them from
        # two different maxima (lexicographic for one, line count for the
        # other) can name chunk-1 as the diff while sizing coverage against
        # chunk-0 when an agent mentions both. max() on (count, path) tuples
        # breaks count ties by path, which is fine — that just picks one of
        # the equally-long files.
        if counted:
            total, diff_path = max(counted)
        elif DIFF_FILE and line_count(DIFF_FILE) is not None:
            total, diff_path = line_count(DIFF_FILE), DIFF_FILE
        else:
            total, diff_path = TOTAL, None

        # A file read covers the patch lines of the new side it returned, and
        # the file's headers so that reading a new file in full reaches 100%.
        if diff_path and file_reads:
            sections = patch_map(diff_path)
            for rel, first, last in file_reads:
                for section in sections.get(rel, []):
                    hit = [p for new, p in section["lines"].items() if first <= new <= last]
                    if hit:
                        intervals.extend([p, p] for p in hit + section["headers"])
                        how.add("file")

        merged = [[a, min(b, total)] for a, b in merge(intervals) if a <= min(b, total)]
        covered = sum(b - a + 1 for a, b in merged)
        gaps = [[merged[i][1] + 1, merged[i + 1][0] - 1] for i in range(len(merged) - 1)]
        if merged and merged[0][0] > 1:
            gaps.insert(0, [1, merged[0][0] - 1])
        if merged and merged[-1][1] < total:
            gaps.append([merged[-1][1] + 1, total])
        if not merged and total:
            gaps = [[1, total]]
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
    print("  grep -n '^diff --git' <diff.patch>")
else:
    print(f"\nEvery agent read at least {MIN_PCT}% of its diff.")
PYTHON
