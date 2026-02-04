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

# Source helpers
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
source "${SCRIPT_DIR}/helpers/git-helpers.sh"
source "${SCRIPT_DIR}/helpers/config-helpers.sh"
source "${SCRIPT_DIR}/helpers/date-helpers.sh"

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

    # Get commits after the review was created
    # Use epoch seconds for reliable date comparison (ISO 8601 string comparison
    # fails when GitHub API returns +00:00 vs Z suffix)
    local review_file_epoch
    review_file_epoch=$(get_file_mtime "${review_file}")

    # Get commits on the PR
    local pr_commits
    pr_commits=$(gh api "repos/${org}/${repo}/pulls/${pr_number}/commits" --jq '
        [.[] | {
            sha: .sha,
            message: .commit.message,
            date: .commit.committer.date,
            files: []
        }]
    ' 2> /dev/null || echo "[]")

    # Get the list of files changed in commits after the review
    local files_changed_after_review="[]"
    while IFS= read -r commit_json; do
        local commit_sha commit_date commit_epoch
        commit_sha=$(echo "${commit_json}" | jq -r '.sha')
        commit_date=$(echo "${commit_json}" | jq -r '.date')

        # Convert commit date to epoch seconds for reliable comparison
        commit_epoch=$(iso_to_epoch "${commit_date}")

        # Check if commit is after review file creation
        if [[ "${commit_epoch}" -gt "${review_file_epoch}" ]]; then
            # Get files changed in this commit
            local commit_files
            commit_files=$(gh api "repos/${org}/${repo}/commits/${commit_sha}" --jq '[.files[].filename]' 2> /dev/null || echo "[]")
            files_changed_after_review=$(echo "${files_changed_after_review}" | jq --argjson files "${commit_files}" '. + $files | unique')
        fi
    done < <(echo "${pr_commits}" | jq -c '.[]')

    # Cross-reference Claude's findings with commit history
    local claude_results="[]"
    while IFS= read -r finding_json; do
        local finding_file finding_line finding_desc finding_agent finding_conf
        finding_file=$(echo "${finding_json}" | jq -r '.file')
        finding_line=$(echo "${finding_json}" | jq -r '.line')
        finding_desc=$(echo "${finding_json}" | jq -r '.description')
        finding_agent=$(echo "${finding_json}" | jq -r '.agent')
        finding_conf=$(echo "${finding_json}" | jq -r '.confidence')

        # Check if this file was modified after the review
        local was_addressed="unknown"
        if echo "${files_changed_after_review}" | jq -e --arg f "${finding_file}" 'index($f) != null' > /dev/null 2>&1; then
            was_addressed="likely"
        else
            was_addressed="not_modified"
        fi

        claude_results=$(echo "${claude_results}" | jq --argjson finding "${finding_json}" \
            --arg addressed "${was_addressed}" \
            '. + [($finding + {addressed: $addressed})]')
    done < <(echo "${claude_findings}" | jq -c '.[]')

    # Extract findings from other reviewers
    local other_findings="[]"
    while IFS= read -r comment_json; do
        local comment_path comment_line comment_body comment_author
        comment_path=$(echo "${comment_json}" | jq -r '.path // empty')
        comment_line=$(echo "${comment_json}" | jq -r '.line // 0')
        comment_body=$(echo "${comment_json}" | jq -r '.body // empty')
        comment_author=$(echo "${comment_json}" | jq -r '.author // empty')

        # Skip comments without file paths (general PR comments)
        [[ -z "${comment_path}" ]] && continue

        # Check if file was modified after this comment
        local was_addressed="unknown"
        if echo "${files_changed_after_review}" | jq -e --arg f "${comment_path}" 'index($f) != null' > /dev/null 2>&1; then
            was_addressed="likely"
        else
            was_addressed="not_modified"
        fi

        # Check if Claude caught this (same file, within 10 lines)
        local claude_caught="false"
        while IFS= read -r claude_finding; do
            local cf_file cf_line
            cf_file=$(echo "${claude_finding}" | jq -r '.file')
            cf_line=$(echo "${claude_finding}" | jq -r '.line')

            if [[ "${cf_file}" == "${comment_path}" ]]; then
                local line_diff=$((comment_line - cf_line))
                if [[ ${line_diff#-} -le 10 ]]; then
                    claude_caught="true"
                    break
                fi
            fi
        done < <(echo "${claude_findings}" | jq -c '.[]')

        other_findings=$(echo "${other_findings}" | jq \
            --arg path "${comment_path}" \
            --arg line "${comment_line}" \
            --arg body "${comment_body}" \
            --arg author "${comment_author}" \
            --arg addressed "${was_addressed}" \
            --arg claude_caught "${claude_caught}" \
            '. + [{
                file: $path,
                line: ($line | tonumber),
                description: $body,
                author: $author,
                addressed: $addressed,
                claude_caught: ($claude_caught == "true")
            }]')
    done < <(echo "${review_comments}" | jq -c '.[]')

    # Determine which findings need user prompts
    local prompts_needed="[]"

    # Claude findings that weren't addressed - ask if false positive
    while IFS= read -r finding_json; do
        local addressed
        addressed=$(echo "${finding_json}" | jq -r '.addressed')
        if [[ "${addressed}" == "not_modified" ]]; then
            prompts_needed=$(echo "${prompts_needed}" | jq --argjson finding "${finding_json}" \
                '. + [{type: "unaddressed", finding: $finding}]')
        fi
    done < <(echo "${claude_results}" | jq -c '.[]')

    # Other reviewer findings that Claude missed - ask if should learn
    while IFS= read -r finding_json; do
        local claude_caught addressed
        claude_caught=$(echo "${finding_json}" | jq -r '.claude_caught')
        addressed=$(echo "${finding_json}" | jq -r '.addressed')
        if [[ "${claude_caught}" == "false" ]] && [[ "${addressed}" == "likely" ]]; then
            prompts_needed=$(echo "${prompts_needed}" | jq --argjson finding "${finding_json}" \
                '. + [{type: "missed", finding: $finding}]')
        fi
    done < <(echo "${other_findings}" | jq -c '.[]')

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
