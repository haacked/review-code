#!/usr/bin/env bash
set -euo pipefail

# split-diff-by-path.sh - Extract the hunks for a set of paths from a unified diff.
#
# The frontend and infra-config reviewers only look at their own file types, so
# they get a diff holding just those files. The paths that were left out are
# listed at the end, so the agent knows the PR is larger than what it sees and
# does not read the omission as "nothing else changed".
#
# Usage:
#   printf '%s\n' path1 path2 | split-diff-by-path.sh <input-diff> <output-diff>
#
# Exits non-zero when no requested path appears in the diff, so the caller can
# fall back to the full diff rather than hand an agent an empty review.

INPUT="${1:-}"
OUTPUT="${2:-}"

if [[ -z "${INPUT}" || -z "${OUTPUT}" ]]; then
    echo "ERROR: Usage: split-diff-by-path.sh <input-diff> <output-diff>" >&2
    exit 1
fi

if [[ ! -f "${INPUT}" ]]; then
    echo "ERROR: Input diff not found: ${INPUT}" >&2
    exit 1
fi

WANTED=$(cat)
if [[ -z "${WANTED}" ]]; then
    exit 1
fi

printf '%s\n' "${WANTED}" | awk -v out="${OUTPUT}" '
    NR == FNR { wanted[$0] = 1; next }

    /^diff --git / {
        # Match on " b/" (with leading space) rather than taking the last field:
        # a path containing spaces would otherwise be truncated to its last word
        # and silently dropped. Same idiom as chunk-diff.sh.
        match($0, / b\/(.+)$/)
        path = (RSTART > 0) ? substr($0, RSTART + 3) : "unknown"
        keep = (path in wanted)
        if (keep) {
            matched++
        } else {
            others = others (others == "" ? "" : ", ") path
        }
    }

    keep { print > out }

    END {
        if (matched == 0) { exit 1 }
        if (others != "") {
            print "" > out
            print "**Other files changed in this PR (not shown above, outside your review scope):**" > out
            print others > out
        }
    }
' - "${INPUT}"
