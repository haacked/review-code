#!/usr/bin/env bash
# shellcheck disable=SC2310  # Functions in conditionals intentionally check return values
# pr-context.sh - Fetch PR data using gh CLI
#
# Usage:
#   pr-context.sh <pr-number-or-url>
#
# Arguments:
#   pr-number-or-url: Either a PR number (e.g., 123) or full PR URL
#
# Output (JSON):
#   {
#     "org": "posthog",
#     "repo": "posthog",
#     "number": 123,
#     "title": "Fix bug in authentication",
#     "body": "This PR fixes...",
#     "url": "https://github.com/PostHog/posthog/pull/123",
#     "author": "haacked",
#     "head_ref": "haacked/fix-auth",
#     "base_ref": "main",
#     "state": "open",
#     "diff": "diff content...",
#     "comments": {
#       "conversation": [...],  # PR discussion thread comments
#       "reviews": [...],       # Review summaries with state
#       "inline": [...]         # Line-level code review comments
#     }
#   }

# Source error helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"

set -euo pipefail

# Check if gh is installed
if ! command -v gh &> /dev/null; then
    error "gh CLI is not installed. Install it with: brew install gh"
    exit 1
fi

# Validate repo_spec format (owner/repo pattern)
# Returns 0 if valid, 1 if invalid
validate_repo_spec() {
    local repo_spec="$1"
    if [[ ! "${repo_spec}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        error "Invalid repo specification: ${repo_spec}"
        return 1
    fi
    return 0
}

# Validate PR number (numeric only)
# Returns 0 if valid, 1 if invalid
validate_pr_number() {
    local pr_number="$1"
    if [[ ! "${pr_number}" =~ ^[0-9]+$ ]]; then
        error "Invalid PR number: ${pr_number}"
        return 1
    fi
    return 0
}

# Parse PR identifier (number or URL)
parse_pr_identifier() {
    local input="$1"

    # If it's a URL, extract the PR number
    if [[ ${input} =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        local org="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local number="${BASH_REMATCH[3]}"

        # Normalize org to lowercase
        org=$(echo "${org}" | tr '[:upper:]' '[:lower:]')

        echo "${org}|${repo}|${number}"
    elif [[ ${input} =~ ^[0-9]+$ ]]; then
        # Just a number, use current repo
        echo "|${input}"
    else
        error "Invalid PR identifier: ${input}"
        echo "Expected: PR number (e.g., 123) or PR URL (e.g., https://github.com/org/repo/pull/123)" >&2
        exit 1
    fi
}

# Fetch PR metadata
fetch_pr_metadata() {
    local pr_number="$1"
    local repo_spec="${2:-}"

    # Use array to prevent command injection
    local gh_cmd=(gh pr view "${pr_number}")
    if [[ -n "${repo_spec}" ]]; then
        gh_cmd+=(--repo "${repo_spec}")
    fi

    DEBUG= "${gh_cmd[@]}" --json number,title,body,url,author,headRefName,baseRefName,state
}

# Fetch PR diff
fetch_pr_diff() {
    local pr_number="$1"
    local repo_spec="${2:-}"

    # Use array to prevent command injection
    local gh_cmd=(gh pr diff "${pr_number}")
    if [[ -n "${repo_spec}" ]]; then
        gh_cmd+=(--repo "${repo_spec}")
    fi

    DEBUG= "${gh_cmd[@]}"
}

# Fetch PR conversation comments (main discussion thread)
# Uses paginated API to handle PRs with many comments.
fetch_conversation_comments() {
    local pr_number="$1"
    local repo_spec="$2"

    # Validate inputs before interpolating into URL
    validate_pr_number "${pr_number}" || return 1
    validate_repo_spec "${repo_spec}" || return 1

    DEBUG= gh api --paginate "repos/${repo_spec}/issues/${pr_number}/comments" \
        | jq -s 'add | [.[] | {id, author: .user.login, body, created_at, url: .html_url}]'
}

# Fetch inline review comments (line-level code feedback)
# Uses paginated API to handle PRs with many review comments.
fetch_inline_comments() {
    local pr_number="$1"
    local repo_spec="$2"

    # Validate inputs before interpolating into URL
    validate_pr_number "${pr_number}" || return 1
    validate_repo_spec "${repo_spec}" || return 1

    DEBUG= gh api --paginate "repos/${repo_spec}/pulls/${pr_number}/comments" \
        | jq -s 'add | [.[] | {id, author: .user.login, body, path, line, side, diff_hunk, created_at, in_reply_to_id, url: .html_url}]'
}

# Fetch review summaries (approval/changes requested with body text)
fetch_reviews() {
    local pr_number="$1"
    local repo_spec="${2:-}"

    local gh_cmd=(gh pr view "${pr_number}" --json reviews)
    if [[ -n "${repo_spec}" ]]; then
        gh_cmd+=(--repo "${repo_spec}")
    fi

    DEBUG= "${gh_cmd[@]}" | jq '.reviews | [.[] | {id, author: .author.login, state, body, submitted_at: .submittedAt}]'
}

# Main logic
main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: pr-context.sh <pr-number-or-url>" >&2
        exit 1
    fi

    local input="$1"
    local parsed
    parsed=$(parse_pr_identifier "${input}")

    local org="" repo="" pr_number=""
    if [[ ${parsed} == "|"* ]]; then
        # Just a number, use current repo
        pr_number="${parsed#|}"
    else
        org="${parsed%%|*}"
        local rest="${parsed#*|}"
        repo="${rest%%|*}"
        pr_number="${rest#*|}"
    fi

    # Build repo spec for gh if needed
    local repo_spec=""
    if [[ -n "${repo}" ]]; then
        repo_spec="${org}/${repo}"
    fi

    # Fetch PR data with error handling
    local metadata
    if ! metadata=$(fetch_pr_metadata "${pr_number}" "${repo_spec}" 2>&1); then
        error "Failed to fetch PR metadata for #${pr_number}: ${metadata}"
        exit 1
    fi

    local diff
    if ! diff=$(fetch_pr_diff "${pr_number}" "${repo_spec}" 2>&1); then
        error "Failed to fetch PR diff for #${pr_number}: ${diff}"
        exit 1
    fi

    # Extract fields from metadata JSON
    local title
    title=$(echo "${metadata}" | jq -r '.title')
    local body
    body=$(echo "${metadata}" | jq -r '.body // ""')
    local url
    url=$(echo "${metadata}" | jq -r '.url')
    local author
    author=$(echo "${metadata}" | jq -r '.author.login')
    local head_ref
    head_ref=$(echo "${metadata}" | jq -r '.headRefName')
    local base_ref
    base_ref=$(echo "${metadata}" | jq -r '.baseRefName')
    local state
    state=$(echo "${metadata}" | jq -r '.state')

    # Extract org/repo from URL if not already set
    if [[ -z "${org}" ]]; then
        if [[ ${url} =~ github\.com/([^/]+)/([^/]+)/pull/ ]]; then
            org="${BASH_REMATCH[1]}"
            repo="${BASH_REMATCH[2]}"
            org=$(echo "${org}" | tr '[:upper:]' '[:lower:]')
        fi
    fi

    # Rebuild repo_spec now that we have org/repo
    if [[ -z "${repo_spec}" && -n "${org}" && -n "${repo}" ]]; then
        repo_spec="${org}/${repo}"
    fi

    # Fetch all comment types (conversation, inline, reviews) with pagination
    local conversation_comments="[]"
    local inline_comments="[]"
    local reviews="[]"

    if [[ -n "${repo_spec}" ]]; then
        if ! conversation_comments=$(fetch_conversation_comments "${pr_number}" "${repo_spec}"); then
            # Non-fatal: log warning but continue
            warning "Failed to fetch conversation comments"
            conversation_comments="[]"
        fi

        if ! inline_comments=$(fetch_inline_comments "${pr_number}" "${repo_spec}"); then
            # Non-fatal: log warning but continue
            warning "Failed to fetch inline comments"
            inline_comments="[]"
        fi
    fi

    if ! reviews=$(fetch_reviews "${pr_number}" "${repo_spec}"); then
        # Non-fatal: log warning but continue
        warning "Failed to fetch reviews"
        reviews="[]"
    fi

    # Escape special characters for JSON
    diff=$(echo "${diff}" | jq -Rs .)
    body=$(echo "${body}" | jq -Rs . | jq -r .)

    # Output combined JSON
    # shellcheck disable=SC2312  # jq failures for title/body sanitization are non-critical
    cat << EOF
{
    "org": "${org}",
    "repo": "${repo}",
    "number": ${pr_number},
    "title": $(echo "${title}" | jq -Rs .),
    "body": $(echo "${body}" | jq -Rs .),
    "url": "${url}",
    "author": "${author}",
    "head_ref": "${head_ref}",
    "base_ref": "${base_ref}",
    "state": "${state}",
    "diff": ${diff},
    "comments": {
        "conversation": ${conversation_comments},
        "reviews": ${reviews},
        "inline": ${inline_comments}
    }
}
EOF
}

# Main execution (only run if script is executed directly, not sourced)
if [[ "${BASH_SOURCE[0]:-}" = "${0}" ]]; then
    main "$@"
fi
