#!/usr/bin/env bash
# learn-from-pr.sh - Cross-reference engine for learning from PR outcomes
#
# Usage:
#   learn-from-pr.sh <pr_number> [--org ORG] [--repo REPO]
#   learn-from-pr.sh <pr_url>
#
# Description:
#   Analyzes a PR's final state to learn from review outcomes:
#   1. Loads Claude's review notes from ~/dev/ai/reviews/{org}/{repo}/pr-{number}.md
#   2. Fetches GitHub review comments (changes requested / resolved threads)
#   3. Gets commit history after reviews were posted
#   4. Cross-references to determine outcomes
#
# Output:
#   JSON with cross-reference results:
#   {
#     "pr_number": 123,
#     "org": "posthog",
#     "repo": "posthog",
#     "claude_findings": [...],
#     "other_findings": [...],
#     "prompts_needed": [...]
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helpers (error-helpers first, then alphabetical)
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
source "${SCRIPT_DIR}/helpers/config-helpers.sh"
source "${SCRIPT_DIR}/helpers/date-helpers.sh"
source "${SCRIPT_DIR}/helpers/git-helpers.sh"

main() {
    local pr_identifier="${1:-}"
    local org=""
    local repo=""

    if [[ -z "${pr_identifier}" ]]; then
        error "Usage: learn-from-pr.sh <pr_number> [--org ORG] [--repo REPO]"
        exit 1
    fi

    # Parse arguments
    shift
    while [[ $# -gt 0 ]]; do
        case $1 in
            --org)
                org="$2"
                shift 2
                ;;
            --repo)
                repo="$2"
                shift 2
                ;;
            *)
                error "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

    # Extract PR number from URL if needed
    local pr_number
    if [[ "${pr_identifier}" =~ ^https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        org="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        pr_number="${BASH_REMATCH[3]}"
    elif [[ "${pr_identifier}" =~ ^[0-9]+$ ]]; then
        pr_number="${pr_identifier}"
    else
        error "Invalid PR identifier: ${pr_identifier}"
        exit 1
    fi

    # Get org/repo from git if not provided
    if [[ -z "${org}" ]] || [[ -z "${repo}" ]]; then
        if git rev-parse --git-dir > /dev/null 2>&1; then
            local git_data
            git_data=$(get_git_org_repo 2> /dev/null || echo "unknown|unknown")
            org="${org:-${git_data%|*}}"
            repo="${repo:-${git_data#*|}}"
        else
            error "Not in a git repository and --org/--repo not provided"
            exit 1
        fi
    fi

    # Load review root path from config
    local review_root
    review_root=$(get_review_root)

    # Check for review file
    local review_file="${review_root}/${org}/${repo}/pr-${pr_number}.md"
    if [[ ! -f "${review_file}" ]]; then
        error "No review file found: ${review_file}"
        error "Run '/review-code ${pr_number}' first to create a review"
        exit 1
    fi

    # Parse Claude's findings from review file
    local claude_findings
    claude_findings=$("${SCRIPT_DIR}/parse-review-findings.sh" "${review_file}")

    # Fetch PR data from GitHub
    local pr_data
    pr_data=$(gh pr view "${pr_number}" --repo "${org}/${repo}" --json number,title,state,mergedAt,createdAt,commits,files,reviews 2> /dev/null) || {
        error "Failed to fetch PR data from GitHub"
        exit 1
    }

    local pr_state
    pr_state=$(echo "${pr_data}" | jq -r '.state')
    local pr_merged_at
    pr_merged_at=$(echo "${pr_data}" | jq -r '.mergedAt // empty')

    # Fetch review comments with threads
    local review_comments
    review_comments=$(gh api "repos/${org}/${repo}/pulls/${pr_number}/comments" --jq '
        [.[] | {
            id: .id,
            path: .path,
            line: .line,
            body: .body,
            author: .user.login,
            created_at: .created_at,
            in_reply_to_id: .in_reply_to_id
        }]
    ' 2> /dev/null || echo "[]")

    # Determine files changed after the review was created
    # Use epoch seconds for reliable date comparison (ISO 8601 string comparison
    # fails when GitHub API returns +00:00 vs Z suffix)
    local review_file_epoch
    review_file_epoch=$(get_file_mtime "${review_file}")

    # Check if any commits are after the review file creation
    # Using the commits data already fetched in pr_data to avoid extra API calls
    local has_commits_after_review=false
    while IFS= read -r commit_date; do
        [[ -z "${commit_date}" ]] && continue
        local commit_epoch
        commit_epoch=$(iso_to_epoch "${commit_date}")
        if [[ "${commit_epoch}" -gt "${review_file_epoch}" ]]; then
            has_commits_after_review=true
            break
        fi
    done < <(echo "${pr_data}" | jq -r '.commits[].committedDate // empty')

    # If commits exist after review, use the PR's file list as files potentially modified
    # This is a conservative approximation - we assume any PR file could have been touched
    # in post-review commits, avoiding N additional API calls to fetch per-commit file lists
    local files_changed_after_review
    if [[ "${has_commits_after_review}" == true ]]; then
        files_changed_after_review=$(echo "${pr_data}" | jq '[.files[].path]')
    else
        files_changed_after_review="[]"
    fi

    # Cross-reference Claude's findings with commit history using jq
    # For each finding, check if its file was modified after the review
    local claude_results
    claude_results=$(jq -n \
        --argjson findings "${claude_findings}" \
        --argjson changed "${files_changed_after_review}" \
        '[$findings[] | . + {
            addressed: (if ($changed | index(.file)) != null then "likely" else "not_modified" end)
        }]')

    # Extract findings from other reviewers and check if Claude caught them
    # This replaces O(n*m) bash loops with a single jq filter
    local other_findings
    other_findings=$(jq -n \
        --argjson comments "${review_comments}" \
        --argjson claude "${claude_findings}" \
        --argjson changed "${files_changed_after_review}" \
        '
        # Filter to comments with file paths and transform
        [$comments[] | select(.path != null and .path != "") |
            # Compute addressed status
            . as $c |
            (if ($changed | index($c.path)) != null then "likely" else "not_modified" end) as $addressed |
            # Check if Claude caught this (same file, within 10 lines)
            ([$claude[] | select(.file == $c.path and ((.line - $c.line) | fabs) <= 10)] | length > 0) as $caught |
            {
                file: $c.path,
                line: ($c.line // 0),
                description: ($c.body // ""),
                author: ($c.author // ""),
                addressed: $addressed,
                claude_caught: $caught
            }
        ]')

    # Determine which findings need user prompts using jq filters
    # (avoids O(n²) bash loops with repeated jq calls)
    local prompts_needed
    prompts_needed=$(jq -n \
        --argjson claude "${claude_results}" \
        --argjson other "${other_findings}" \
        '
        # Claude findings that were not addressed - ask if false positive
        [$claude[] | select(.addressed == "not_modified") | {type: "unaddressed", finding: .}]
        +
        # Other reviewer findings that Claude missed - ask if should learn
        [$other[] | select(.claude_caught == false and .addressed == "likely") | {type: "missed", finding: .}]
        ')

    # Build final output
    jq -n \
        --arg pr_number "${pr_number}" \
        --arg org "${org}" \
        --arg repo "${repo}" \
        --arg state "${pr_state}" \
        --arg merged_at "${pr_merged_at}" \
        --arg review_file "${review_file}" \
        --argjson claude_findings "${claude_results}" \
        --argjson other_findings "${other_findings}" \
        --argjson prompts_needed "${prompts_needed}" \
        --argjson files_changed "${files_changed_after_review}" \
        '{
            pr_number: ($pr_number | tonumber),
            org: $org,
            repo: $repo,
            state: $state,
            merged_at: (if $merged_at == "" then null else $merged_at end),
            review_file: $review_file,
            claude_findings: $claude_findings,
            other_findings: $other_findings,
            prompts_needed: $prompts_needed,
            files_changed_after_review: $files_changed,
            summary: {
                claude_total: ($claude_findings | length),
                claude_addressed: ([$claude_findings[] | select(.addressed == "likely")] | length),
                claude_not_addressed: ([$claude_findings[] | select(.addressed == "not_modified")] | length),
                other_total: ($other_findings | length),
                other_caught_by_claude: ([$other_findings[] | select(.claude_caught == true)] | length),
                other_missed_by_claude: ([$other_findings[] | select(.claude_caught == false)] | length)
            }
        }'
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
