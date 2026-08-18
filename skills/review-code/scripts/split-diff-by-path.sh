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

printf '%s\n' "${WANTED}" | awk -v diff="${INPUT}" -v out="${OUTPUT}" '
    { wanted[$0] = 1 }
    END {
        keep = 0
        matched = 0
        while ((getline line < diff) > 0) {
            if (line ~ /^diff --git /) {
                # "diff --git a/path b/path" - take the b-side, which survives renames.
                path = $0
                n = split(line, parts, " ")
                path = parts[n]
                sub(/^b\//, "", path)
                keep = (path in wanted)
                if (keep) { matched++ } else { omitted[path] = 1 }
            }
            if (keep) { print line > out }
        }
        close(diff)

        if (matched == 0) { exit 1 }

        first = 1
        others = ""
        for (p in omitted) {
            others = others (first ? "" : ", ") p
            first = 0
        }
        if (others != "") {
            print "" > out
            print "**Other files changed in this PR (not shown above, outside your review scope):**" > out
            print others > out
        }
        close(out)
    }
'
