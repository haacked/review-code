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

# Parse a unified diff in a single pass, producing two outputs:
#   - modified_file: "file:line" entries for each added/deleted line
#   - deleted_file: file paths of fully deleted files (+++ /dev/null)
parse_diff() {
    local diff="$1"
    local modified_out="$2"
    local deleted_out="$3"

    echo "${diff}" | awk -v modified_out="${modified_out}" -v deleted_out="${deleted_out}" '
    BEGIN { current_file = ""; is_deleted = 0 }

    /^diff --git/ {
        idx = index($0, " b/")
        if (idx > 0) current_file = substr($0, idx + 3)
        else current_file = ""
        is_deleted = 0
        next
    }

    /^\+\+\+ \/dev\/null/ {
        if (current_file != "") {
            print current_file > deleted_out
            is_deleted = 1
        }
        next
    }

    /^@@/ {
        s = $0
        idx = index(s, "+")
        if (idx > 0) {
            rest = substr(s, idx + 1)
            new_line = rest + 0
            if (new_line < 1) new_line = 1
        }
        next
    }

    current_file != "" && /^\+/ && !/^\+\+\+/ {
        print current_file ":" new_line > modified_out
        new_line++
        next
    }

    current_file != "" && /^-/ && !/^---/ {
        print current_file ":" new_line > modified_out
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

    local findings diff
    findings=$(echo "${input}" | jq -c '.findings // []')
    if [[ "${findings}" == "[]" ]]; then
        echo "[]"
        return 0
    fi
    diff=$(echo "${input}" | jq -r '.diff // ""')

    # Parse diff into temp files to avoid ARG_MAX limits
    local modified_file deleted_file
    modified_file=$(mktemp)
    deleted_file=$(mktemp)
    trap 'rm -f "${modified_file}" "${deleted_file}"' RETURN
    if [[ -n "${diff}" ]]; then
        parse_diff "${diff}" "${modified_file}" "${deleted_file}"
    fi

    echo "${findings}" | jq -c --rawfile modified "${modified_file}" --rawfile deleted "${deleted_file}" '
        # Build lookup sets via single-pass reduce
        ($modified | split("\n") |
            reduce .[] as $line ({}; if $line != "" then . + {($line): true} else . end)
        ) as $modified_set |
        ($deleted | split("\n") |
            reduce .[] as $line ({}; if $line != "" then . + {($line): true} else . end)
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
