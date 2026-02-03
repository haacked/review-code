#!/usr/bin/env bash
# learn-batch.sh - Find unanalyzed PRs with Claude reviews
#
# Usage:
#   learn-batch.sh [--limit N] [--days N]
#
# Description:
#   Finds recently merged PRs that have Claude review files but haven't been
#   analyzed for learning yet. Tracks analyzed PRs in learnings/analyzed.json.
#
# Options:
#   --limit N   Maximum number of PRs to return (default: 10)
#   --days N    Only consider PRs merged in the last N days (default: 30)
#
# Output:
#   JSON array of unanalyzed PRs:
#   [
#     {
#       "org": "posthog",
#       "repo": "posthog",
#       "pr_number": 123,
#       "review_file": "/path/to/pr-123.md",
#       "merged_at": "2026-01-15T10:30:00Z"
#     }
#   ]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEARNINGS_DIR="${SCRIPT_DIR}/../learnings"

# Source helpers
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
source "${SCRIPT_DIR}/helpers/config-helpers.sh"

main() {
    local limit=10
    local days=30

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --limit)
                if [[ $# -lt 2 ]]; then
                    error "Missing value for --limit"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -le 0 ]]; then
                    error "--limit must be a positive integer, got: \"$2\""
                    exit 1
                fi
                limit="$2"
                shift 2
                ;;
            --days)
                if [[ $# -lt 2 ]]; then
                    error "Missing value for --days"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -le 0 ]]; then
                    error "--days must be a positive integer, got: \"$2\""
                    exit 1
                fi
                days="$2"
                shift 2
                ;;
            *)
                error "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

    # Load review root path from config
    local review_root
    review_root=$(get_review_root)

    # Ensure learnings directory exists
    mkdir -p "${LEARNINGS_DIR}"

    # Load analyzed PRs tracker
    local analyzed_file="${LEARNINGS_DIR}/analyzed.json"
    local analyzed_data="{}"
    if [[ -f "${analyzed_file}" ]]; then
        analyzed_data=$(cat "${analyzed_file}")
    fi

    # Calculate cutoff date
    local cutoff_date
    if [[ "${OSTYPE}" == "darwin"* ]]; then
        cutoff_date=$(date -v-"${days}"d -u +"%Y-%m-%dT%H:%M:%SZ")
    else
        cutoff_date=$(date -d "${days} days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    fi

    # Find all PR review files
    local unanalyzed_prs="[]"
    local count=0

    # Check if review_root exists
    if [[ ! -d "${review_root}" ]]; then
        echo "${unanalyzed_prs}"
        exit 0
    fi

    # Find all pr-*.md files in the review directory
    while IFS= read -r review_file; do
        [[ ${count} -ge ${limit} ]] && break

        # Extract org, repo, and PR number from path
        # Path format: {review_root}/{org}/{repo}/pr-{number}.md
        local relative_path="${review_file#"${review_root}/"}"
        local org repo pr_number

        # Parse path components
        org=$(echo "${relative_path}" | cut -d'/' -f1)
        repo=$(echo "${relative_path}" | cut -d'/' -f2)
        local filename
        filename=$(basename "${review_file}")

        # Extract PR number from filename (pr-123.md -> 123)
        if [[ "${filename}" =~ ^pr-([0-9]+)\.md$ ]]; then
            pr_number="${BASH_REMATCH[1]}"
        else
            continue
        fi

        # Check if already analyzed
        # Use // {} to handle missing repo key gracefully instead of relying on error suppression
        local repo_key="${org}/${repo}"
        if echo "${analyzed_data}" | jq -e --arg key "${repo_key}" --arg pr "${pr_number}" '(.[$key] // {})[$pr] != null' > /dev/null 2>&1; then
            continue
        fi

        # Check PR state and merge date via GitHub API
        local pr_data
        pr_data=$(gh api "repos/${org}/${repo}/pulls/${pr_number}" --jq '{state: .state, merged_at: .merged_at}' 2> /dev/null || echo '{"state":"unknown","merged_at":null}')

        local pr_state pr_merged_at
        pr_state=$(echo "${pr_data}" | jq -r '.state')
        pr_merged_at=$(echo "${pr_data}" | jq -r '.merged_at // empty')

        # Skip if not merged
        if [[ -z "${pr_merged_at}" ]] || [[ "${pr_merged_at}" == "null" ]]; then
            continue
        fi

        # Skip if merged before cutoff date
        if [[ "${pr_merged_at}" < "${cutoff_date}" ]]; then
            continue
        fi

        # Add to results
        unanalyzed_prs=$(echo "${unanalyzed_prs}" | jq \
            --arg org "${org}" \
            --arg repo "${repo}" \
            --arg pr_number "${pr_number}" \
            --arg review_file "${review_file}" \
            --arg merged_at "${pr_merged_at}" \
            '. + [{
                org: $org,
                repo: $repo,
                pr_number: ($pr_number | tonumber),
                review_file: $review_file,
                merged_at: $merged_at
            }]')

        count=$((count + 1))
    done < <(find "${review_root}" -name "pr-*.md" -type f 2> /dev/null | sort -r)

    echo "${unanalyzed_prs}"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
