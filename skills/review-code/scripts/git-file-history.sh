#!/usr/bin/env bash
# git-file-history.sh - Compute git history metrics for files
#
# Usage:
#   echo -e "path/to/file1\npath/to/file2" | git-file-history.sh
#
# Input:
#   Newline-delimited file paths on stdin
#
# Output (JSON):
#   {
#     "path/to/file1": {
#       "recent_commits": 12,
#       "recent_authors": 4,
#       "last_modified": "2026-03-18",
#       "high_churn": true
#     }
#   }
#
# Thresholds:
#   high_churn = true when recent_commits >= 10 OR recent_authors >= 3
#   History window: 30 days
#   Max files: 50

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared helpers
source "${SCRIPT_DIR}/helpers/git-helpers.sh"

# Thresholds
COMMIT_THRESHOLD=10
AUTHOR_THRESHOLD=3
MAX_FILES=50

main() {
    validate_git_repo

    local file_count=0

    # Build ndjson (one object per file), then merge into a single object
    local ndjson=""

    while IFS= read -r file_path; do
        [[ -z "${file_path}" ]] && continue

        file_count=$((file_count + 1))
        if [[ ${file_count} -gt ${MAX_FILES} ]]; then
            continue
        fi

        # Single git log call: author email and date in one pass (tab-separated)
        local log_output
        log_output=$(git log --since="30 days ago" --format="%ae%x09%as" -- "${file_path}" 2> /dev/null || echo "")

        local recent_commits=0
        local recent_authors=0
        local last_modified=""

        if [[ -n "${log_output}" ]]; then
            recent_commits=$(echo "${log_output}" | wc -l | tr -d ' ')
            recent_authors=$(echo "${log_output}" | cut -f1 | sort -u | wc -l | tr -d ' ')
            last_modified=$(echo "${log_output}" | head -1 | cut -f2)
        fi

        # For files dormant >30 days, fetch absolute last_modified
        if [[ -z "${last_modified}" ]]; then
            last_modified=$(git log -1 --format="%as" -- "${file_path}" 2> /dev/null || echo "")
        fi

        # Determine high churn
        local high_churn=false
        if [[ ${recent_commits} -ge ${COMMIT_THRESHOLD} ]] || [[ ${recent_authors} -ge ${AUTHOR_THRESHOLD} ]]; then
            high_churn=true
        fi

        # Build JSON entry using jq for safe escaping
        ndjson+=$(jq -nc \
            --arg path "${file_path}" \
            --argjson commits "${recent_commits}" \
            --argjson authors "${recent_authors}" \
            --arg modified "${last_modified}" \
            --argjson churn "${high_churn}" \
            '{($path): {recent_commits: $commits, recent_authors: $authors, last_modified: (if $modified == "" then null else $modified end), high_churn: $churn}}')
        ndjson+=$'\n'

    done

    # Merge all per-file objects into one; empty input produces {}
    if [[ -n "${ndjson}" ]]; then
        echo "${ndjson}" | jq -s 'add'
    else
        echo "{}"
    fi
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
