#!/usr/bin/env bash
set -euo pipefail
# diff-position-mapper.sh - Map file line numbers to diff line/side for GitHub API
#
# GitHub's PR review comment API accepts either deprecated "position" or the
# preferred "line" + "side" parameters. This script maps file:line targets
# to their corresponding line numbers and side (LEFT for old, RIGHT for new).
# Targets may specify a side. Without one, RIGHT takes precedence over LEFT.
#
# Usage:
#   echo '<json_input>' | diff-position-mapper.sh
#   echo '<json_input>' | diff-position-mapper.sh --diff-file <path>
#
# Input JSON:
#   {
#     "diff": "<unified diff content>",
#     "targets": [
#       {"path": "src/auth.ts", "line": 42},
#       {"path": "src/utils.ts", "line": 15}
#     ]
#   }
#
# With --diff-file the diff is read from that file and the input JSON carries
# only "targets". Callers that already have the diff on disk use this so the
# bytes never pass through a caller's context on the way here.
#
# Output JSON:
#   {
#     "mappings": [
#       {"path": "src/auth.ts", "line": 42, "side": "RIGHT"},
#       {"path": "src/utils.ts", "line": 15, "error": "line not in diff"}
#     ]
#   }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=lib/helpers/json-helpers.sh
source "${SCRIPT_DIR}/helpers/json-helpers.sh"
# shellcheck source=lib/helpers/git-diff-paths.sh
source "${SCRIPT_DIR}/helpers/git-diff-paths.sh"

# Keys include the side because old and new line numbers can overlap.
build_position_map() {
    local diff="$1"

    echo "${diff}" | LC_ALL=C awk "$(git_diff_path_functions)"'
    function open_file() {
        if (current_file == "" || file_open) return
        if (!first_file) print ","
        first_file = 0
        printf "  %s: {", json_quote(current_file)
        first_line = 1
        file_open = 1
    }
    function close_file() {
        if (current_file != "") {
            open_file()
            print "\n  }"
        }
        current_file = ""
        file_open = 0
    }
    function emit_line(line, side) {
        if (!first_line) printf ","
        first_line = 0
        printf "\n    \"%s:%d\": {\"line\": %d, \"side\": \"%s\"}", side, line, line, side
    }
    BEGIN {
        print "{"
        first_file = 1
    }
    /^diff --git / {
        close_file()
        current_file = diff_header_path($0)
        old_file = ""
        in_hunk = 0
        next
    }
    !in_hunk && /^rename to / { current_file = diff_rename_path($0); next }
    !in_hunk && /^--- "?a\// { old_file = diff_marker_path($0); next }
    !in_hunk && /^\+\+\+ / {
        if ($0 ~ /^\+\+\+ \/dev\/null([[:space:]]|$)/) current_file = old_file
        else if ($0 ~ /^\+\+\+ "?b\//) current_file = diff_marker_path($0)
        next
    }
    /^@@ / {
        open_file()
        rest = substr($0, index($0, "-") + 1)
        sub(/[^0-9].*/, "", rest)
        old_line = rest + 0
        rest = substr($0, index($0, "+") + 1)
        sub(/[^0-9].*/, "", rest)
        new_line = rest + 0
        in_hunk = 1
        next
    }
    current_file == "" || !in_hunk { next }
    # GitHub requires RIGHT for unchanged context.
    /^ / || /^$/ {
        old_line++
        emit_line(new_line++, "RIGHT")
        next
    }
    /^\+/ { emit_line(new_line++, "RIGHT"); next }
    /^-/ { emit_line(old_line++, "LEFT"); next }
    END {
        close_file()
        print "}"
    }
    '
}

lookup_positions() {
    local position_map="$1"
    local targets="$2"

    echo "${position_map}" | jq --argjson targets "${targets}" '
        . as $positions
        | {mappings: [$targets[]
            | .path as $path
            | .line as $line
            | (.side // "") as $side
            | if $side != "" and $side != "LEFT" and $side != "RIGHT" then
                error("Target side must be LEFT or RIGHT")
              else
                $positions[$path] as $file
                | if $file == null then
                    {path: $path, line: $line, error: "file not in diff"}
                  else
                    (if $side == "" then
                        $file["RIGHT:" + ($line | tostring)] // $file["LEFT:" + ($line | tostring)]
                    else
                        $file[$side + ":" + ($line | tostring)]
                    end) as $position
                    | if $position == null then
                        {path: $path, line: $line, error: "line not in diff"}
                      else
                        {path: $path, line: $line} + $position
                      end
                  end
              end
        ]}
    '
}

main() {
    local diff_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --diff-file)
                diff_file="${2:-}"
                if [[ -z "${diff_file}" ]]; then
                    error "--diff-file requires a path"
                    exit 1
                fi
                shift 2
                ;;
            *)
                error "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

    # Read input JSON from stdin
    local input
    input=$(cat)

    # Validate input
    validate_json "${input}" || exit 1

    # Extract diff and targets
    local diff targets
    if [[ -n "${diff_file}" ]]; then
        if [[ ! -f "${diff_file}" ]]; then
            error "Diff file not found: ${diff_file}"
            exit 1
        fi
        diff=$(cat "${diff_file}")
    else
        diff=$(echo "${input}" | jq -r '.diff // ""')
    fi
    targets=$(echo "${input}" | jq -c '.targets // []')

    if [[ -z "${diff}" ]]; then
        error "No diff provided in input"
        exit 1
    fi

    # Build the position map once
    local position_map
    position_map=$(build_position_map "${diff}")

    lookup_positions "${position_map}" "${targets}"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
