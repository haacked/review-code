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

# Source helpers (error-helpers first, then alphabetical)
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
source "${SCRIPT_DIR}/helpers/config-helpers.sh"
source "${SCRIPT_DIR}/helpers/date-helpers.sh"
source "${SCRIPT_DIR}/helpers/validation-helpers.sh"

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
                require_positive_int "--limit" "$2"
                limit="$2"
                shift 2
                ;;
            --days)
                if [[ $# -lt 2 ]]; then
                    error "Missing value for --days"
                    exit 1
                fi
                require_positive_int "--days" "$2"
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

    # Load PR status cache (stores merge status to avoid repeated API calls)
    local cache_file="${LEARNINGS_DIR}/status-cache.json"
    local cache_data="{}"
    if [[ -f "${cache_file}" ]]; then
        cache_data=$(cat "${cache_file}")
    fi
    local cache_updated=false

    # Calculate cutoff date
    local cutoff_date
    cutoff_date=$(days_ago_iso "${days}")

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

        # Check PR state and merge date (use cache to avoid repeated API calls)
        local cached_entry
        cached_entry=$(echo "${cache_data}" | jq -r --arg key "${repo_key}" --arg pr "${pr_number}" '.[$key][$pr] // empty')

        local pr_merged_at=""
        local pr_state=""

        if [[ -n "${cached_entry}" ]]; then
            # Check if cache entry is usable
            local cached_state cached_merged_at cached_at
            cached_state=$(echo "${cached_entry}" | jq -r '.state // empty')
            cached_merged_at=$(echo "${cached_entry}" | jq -r '.merged_at // empty')
            cached_at=$(echo "${cached_entry}" | jq -r '.cached_at // empty')

            if [[ "${cached_state}" == "merged" ]]; then
                # Merged PRs are cached forever
                pr_merged_at="${cached_merged_at}"
                pr_state="merged"
            elif [[ -n "${cached_at}" ]]; then
                # Open/closed PRs: check if cache is less than 1 hour old
                local cached_epoch current_epoch
                cached_epoch=$(iso_to_epoch "${cached_at}")
                current_epoch=$(date +%s)
                local cache_age=$((current_epoch - cached_epoch))

                if [[ ${cache_age} -lt 3600 ]]; then
                    # Cache is fresh, use cached state
                    pr_state="${cached_state}"
                    pr_merged_at="${cached_merged_at}"
                fi
            fi
        fi

        # If not cached or cache expired, fetch from API
        if [[ -z "${pr_state}" ]]; then
            local pr_data
            pr_data=$(gh api "repos/${org}/${repo}/pulls/${pr_number}" --jq '{state: .state, merged_at: .merged_at}' 2> /dev/null || echo '{"state":"unknown","merged_at":null}')

            pr_merged_at=$(echo "${pr_data}" | jq -r '.merged_at // empty')
            local api_state
            api_state=$(echo "${pr_data}" | jq -r '.state // "unknown"')

            # Determine state for caching
            if [[ -n "${pr_merged_at}" ]] && [[ "${pr_merged_at}" != "null" ]]; then
                pr_state="merged"
            else
                pr_state="${api_state}"
                pr_merged_at=""
            fi

            # Update cache
            local now_iso
            now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            cache_data=$(echo "${cache_data}" | jq \
                --arg key "${repo_key}" \
                --arg pr "${pr_number}" \
                --arg state "${pr_state}" \
                --arg merged_at "${pr_merged_at}" \
                --arg cached_at "${now_iso}" \
                'if .[$key] == null then .[$key] = {} else . end |
                 .[$key][$pr] = {state: $state, merged_at: (if $merged_at == "" then null else $merged_at end), cached_at: $cached_at}')
            cache_updated=true
        fi

        # Skip if not merged
        if [[ "${pr_state}" != "merged" ]] || [[ -z "${pr_merged_at}" ]]; then
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

    # Save cache if updated
    if [[ "${cache_updated}" == true ]]; then
        echo "${cache_data}" > "${cache_file}"
    fi

    echo "${unanalyzed_prs}"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
