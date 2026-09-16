#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=helpers/git-diff-paths.sh
source "${SCRIPT_DIR}/helpers/git-diff-paths.sh"

# split-diff-by-path.sh - Extract the hunks for a set of paths from a unified diff.
#
# The frontend and infra-config reviewers only look at their own file types, so
# they get a diff holding just those files. The paths that were left out are
# listed at the end, so the agent knows the PR is larger than what it sees and
# does not read the omission as "nothing else changed".
#
# Usage:
#   printf '%s\n' path1 path2 | split-diff-by-path.sh <input-diff> <output-diff>
#   jq -r '.paths[] | @json' | split-diff-by-path.sh --json-paths <input-diff> <output-diff>
#
# Exits non-zero when no requested path appears in the diff, so the caller can
# fall back to the full diff rather than hand an agent an empty review.

JSON_PATHS=false
if [[ "${1:-}" == "--json-paths" ]]; then
    JSON_PATHS=true
    shift
fi

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

LC_ALL=C awk -v out="${OUTPUT}" -v json_paths="${JSON_PATHS}" "$(git_diff_path_functions)"'
    FILENAME == "-" { wanted[$0] = 1; next }

    function emit_block(key) {
        if (block == "") return
        key = json_paths == "true" ? json_quote(path) : path
        if (key in wanted) {
            printf "%s", block > out
            matched++
        } else {
            others = others (others == "" ? "" : ", ") key
        }
        block = ""
    }

    /^diff --git / {
        emit_block()
        path = diff_header_path($0)
        block = $0 ORS
        next
    }

    /^rename to / { path = diff_rename_path($0) }

    { block = block $0 ORS }

    END {
        emit_block()
        if (matched == 0) { exit 1 }
        if (others != "") {
            print "" > out
            print "**Other files changed in this PR (not shown above, outside your review scope):**" > out
            print others > out
        }
    }
' - "${INPUT}"
