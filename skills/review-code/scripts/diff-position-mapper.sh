#!/usr/bin/env bash
# diff-position-mapper.sh - Map file line numbers to diff line/side for GitHub API
#
# GitHub's PR review comment API accepts either deprecated "position" or the
# preferred "line" + "side" parameters. This script maps file:line targets
# to their corresponding line numbers and side (RIGHT for new file lines).
#
# Usage:
#   echo '<json_input>' | diff-position-mapper.sh
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
# Output JSON:
#   {
#     "mappings": [
#       {"path": "src/auth.ts", "line": 42, "side": "RIGHT"},
#       {"path": "src/utils.ts", "line": 15, "line": null, "error": "line not in diff"}
#     ]
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=lib/helpers/json-helpers.sh
source "${SCRIPT_DIR}/helpers/json-helpers.sh"

# Parse the diff and build a lookup table mapping file paths and line numbers
# Lines that appear in the diff (added or context lines) are mapped with their side
#
# Args: $1 = diff content
# Output: JSON object with structure: { "file/path.ts": { "42": {"line": 42, "side": "RIGHT"}, ... }, ... }
build_position_map() {
    local diff="$1"

    # Use awk to parse the diff and output JSON (BSD awk compatible)
    echo "${diff}" | awk '
    BEGIN {
        current_file = ""
        position = 0
        old_line = 0
        new_line = 0
        print "{"
        first_file = 1
    }

    # Match diff header to get file path
    # Format: diff --git a/path/to/file b/path/to/file
    /^diff --git/ {
        # Extract the b/ path (new file) - find last " b/" and take everything after
        idx = match($0, / b\//)
        if (idx > 0) {
            if (current_file != "") {
                print "}"
            }
            if (!first_file) {
                print ","
            }
            first_file = 0
            current_file = substr($0, idx + 3)
            # Escape quotes in file path
            gsub(/"/, "\\\"", current_file)
            printf "  \"%s\": {", current_file
            position = 0
            first_line = 1
        }
        next
    }

    # Match hunk header
    # Format: @@ -old_start,old_count +new_start,new_count @@
    /^@@/ {
        # Parse hunk header manually for BSD awk compatibility
        # Find the +N part for new line start
        idx = index($0, "+")
        if (idx > 0) {
            rest = substr($0, idx + 1)
            # Extract number until comma or space
            gsub(/[^0-9].*/, "", rest)
            new_line = rest + 0
        }
        # Find the -N part for old line start
        idx = index($0, "-")
        if (idx > 0) {
            rest = substr($0, idx + 1)
            gsub(/[^0-9].*/, "", rest)
            old_line = rest + 0
        }
        position++
        next
    }

    # Skip if no current file (before first diff header)
    current_file == "" { next }

    # Context line (space prefix) - both sides have this line
    /^ / {
        position++
        if (!first_line) printf ","
        first_line = 0
        printf "\n    \"%d\": {\"line\": %d, \"side\": \"RIGHT\"}", new_line, new_line
        old_line++
        new_line++
        next
    }

    # Added line (+) - only in new file (RIGHT side)
    /^\+/ && !/^\+\+\+/ {
        position++
        if (!first_line) printf ","
        first_line = 0
        printf "\n    \"%d\": {\"line\": %d, \"side\": \"RIGHT\"}", new_line, new_line
        new_line++
        next
    }

    # Removed line (-) - only in old file (LEFT side)
    /^-/ && !/^---/ {
        position++
        old_line++
        next
    }

    END {
        if (current_file != "") {
            print "\n  }"
        }
        print "}"
    }
    '
}

# Look up a target in the position map
# Args: $1 = position_map (JSON), $2 = path, $3 = line
# Output: JSON object with position info or error
lookup_position() {
    local position_map="$1"
    local path="$2"
    local line="$3"

    # Query the position map
    local result
    result=$(echo "${position_map}" | jq -r --arg path "${path}" --arg line "${line}" '
        .[$path][$line] // null
    ')

    if [[ "${result}" == "null" ]]; then
        # Check if file exists in diff at all
        local file_exists
        file_exists=$(echo "${position_map}" | jq -r --arg path "${path}" 'has($path)')

        if [[ "${file_exists}" == "false" ]]; then
            jq -n --arg path "${path}" --argjson line "${line}" \
                '{path: $path, line: $line, error: "file not in diff"}'
        else
            jq -n --arg path "${path}" --argjson line "${line}" \
                '{path: $path, line: $line, error: "line not in diff"}'
        fi
    else
        # Return the position info with path and line included
        echo "${result}" | jq --arg path "${path}" --argjson line "${line}" \
            '{path: $path, line: $line} + .'
    fi
}

main() {
    # Read input JSON from stdin
    local input
    input=$(cat)

    # Validate input
    validate_json "${input}" || exit 1

    # Extract diff and targets
    local diff targets
    diff=$(echo "${input}" | jq -r '.diff // ""')
    targets=$(echo "${input}" | jq -c '.targets // []')

    if [[ -z "${diff}" ]]; then
        error "No diff provided in input"
        exit 1
    fi

    # Build the position map once
    local position_map
    position_map=$(build_position_map "${diff}")

    # Process each target
    local mappings="[]"
    while IFS= read -r target; do
        local path line
        path=$(echo "${target}" | jq -r '.path')
        line=$(echo "${target}" | jq -r '.line')

        local mapping
        mapping=$(lookup_position "${position_map}" "${path}" "${line}")
        mappings=$(echo "${mappings}" | jq --argjson m "${mapping}" '. + [$m]')
    done < <(echo "${targets}" | jq -c '.[]')

    # Output result
    jq -n --argjson mappings "${mappings}" '{mappings: $mappings}'
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
