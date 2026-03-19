#!/usr/bin/env bash
# check-findings-addressed.sh - Cross-reference findings against a diff to detect fixes
#
# Usage:
#   echo '<json_input>' | check-findings-addressed.sh
#
# Input JSON:
#   {
#     "findings": [<output from parse-review-findings.sh>],
#     "diff": "<unified diff content>"
#   }
#
# Output:
#   JSON array of findings with an added `auto_status` field:
#   - "concluded": finding already has a CONCLUSION annotation
#   - "likely_fixed": referenced lines were modified in the diff
#   - "still_open": file not in diff or referenced lines untouched
#   - "inconclusive": no file reference to check against

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"

# Extract file paths of fully deleted files from a unified diff.
# Output: one file path per line for each deleted file.
build_deleted_files() {
    local diff="$1"

    echo "${diff}" | awk '
    /^diff --git/ {
        idx = index($0, " b/")
        if (idx > 0) pending_file = substr($0, idx + 3)
        else pending_file = ""
        next
    }
    /^\+\+\+ \/dev\/null/ {
        if (pending_file != "") print pending_file
        next
    }
    { next }
    '
}

# Build a set of modified lines from a unified diff.
# Output: one "file:line" per line for each added/modified line in the diff.
build_modified_lines() {
    local diff="$1"

    echo "${diff}" | awk '
    BEGIN { current_file = "" }

    # Match diff header to get file path
    /^diff --git/ {
        idx = index($0, " b/")
        if (idx > 0) {
            current_file = substr($0, idx + 3)
        }
        next
    }

    # Match hunk header to get starting line number
    # Format: @@ -old,count +new,count @@
    /^@@/ {
        s = $0
        idx = index(s, "+")
        if (idx > 0) {
            rest = substr(s, idx + 1)
            # Extract number before comma or space
            new_line = rest + 0
            # Clamp to 1 for deleted-file hunks (+0,0)
            if (new_line < 1) new_line = 1
        }
        next
    }

    # Track line numbers through the hunk
    current_file != "" && /^\+/ && !/^\+\+\+/ {
        print current_file ":" new_line
        new_line++
        next
    }

    current_file != "" && /^-/ && !/^---/ {
        # Mark current position as touched so deletions count as modifications
        print current_file ":" new_line
        next
    }

    current_file != "" && /^ / {
        new_line++
        next
    }
    '
}

main() {
    local input
    input=$(cat)

    # Extract both fields and check for empty findings
    local findings diff extracted
    extracted=$(echo "${input}" | jq -c '{f: (.findings // []), d: (.diff // "")}')
    findings=$(echo "${extracted}" | jq -c '.f')
    if [[ "${findings}" == "[]" ]]; then
        echo "[]"
        return 0
    fi
    diff=$(echo "${extracted}" | jq -r '.d')

    # Build modified lines and deleted files to temp files to avoid ARG_MAX limits
    local modified_file deleted_file
    modified_file=$(mktemp)
    deleted_file=$(mktemp)
    trap 'rm -f "${modified_file}" "${deleted_file}"' RETURN
    if [[ -n "${diff}" ]]; then
        build_modified_lines "${diff}" > "${modified_file}"
        build_deleted_files "${diff}" > "${deleted_file}"
    fi

    echo "${findings}" | jq -c --rawfile modified "${modified_file}" --rawfile deleted "${deleted_file}" '
        # Build a set of exact "file:line" strings from modified lines
        ($modified | split("\n") | map(select(. != "")) |
            map({(.): true}) | add // {}
        ) as $modified_set |
        # Build a set of fully deleted file paths
        ($deleted | split("\n") | map(select(. != "")) |
            map({(.): true}) | add // {}
        ) as $deleted_set |
        [.[] | . + {
            auto_status: (
                if .conclusion != null then "concluded"
                elif (.file == "" or .file == null or .line == 0 or .line == null) then "inconclusive"
                elif ($deleted_set[.file] == true) then "likely_fixed"
                else
                    # Check symmetric window: any modified line within ±10 of the finding
                    .file as $f | .line as $l |
                    if (
                        [range(($l - 10 | if . < 1 then 1 else . end); $l + 11)] |
                        any(. as $ln | $modified_set["\($f):\($ln)"] == true)
                    ) then "likely_fixed"
                    else "still_open"
                    end
                end
            )
        }]
    '
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
