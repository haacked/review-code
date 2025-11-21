#!/usr/bin/env bash
# git-helpers.sh - Shared git helper functions
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/helpers/git-helpers.sh"

# Validate we're in a git repository

# Source error helpers
_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "$_HELPER_DIR/error-helpers.sh"

validate_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        error "Not in a git repository"
        exit 1
    fi
}

# Extract org and repo from git remote URL
# Returns: "org|repo" on success, exits on error
get_git_org_repo() {
    local remote_url
    remote_url=$(git config --get remote.origin.url || echo "")

    # Handle missing remote (local-only repos, tests)
    if [ -z "$remote_url" ]; then
        echo "unknown|unknown"
        return 0
    fi

    # Validate URL format - only allow safe characters to prevent injection
    # Allow: alphanumeric, @, :, /, ., -, _
    if [[ ! $remote_url =~ ^[a-zA-Z0-9@:/._-]+$ ]]; then
        error "Git remote URL contains invalid characters: $remote_url"
        exit 1
    fi

    # Extract org and repo from URL
    # Handles both SSH (git@github.com:PostHog/posthog.git) and HTTPS (https://github.com/PostHog/posthog.git)
    if [[ $remote_url =~ ^(https://|git@)github\.com[:/]([a-zA-Z0-9_-]+)/([a-zA-Z0-9._-]+)(\.git)?$ ]]; then
        local org="${BASH_REMATCH[2]}"
        local repo="${BASH_REMATCH[3]}"

        # Normalize org to lowercase (PostHog → posthog)
        org=$(echo "$org" | tr '[:upper:]' '[:lower:]')

        # Remove .git suffix if present
        repo="${repo%.git}"

        echo "$org|$repo"
    else
        error "Could not parse git remote URL: $remote_url"
        exit 1
    fi
}

# Get current git branch name
get_current_branch() {
    git branch --show-current
}

# Parse PR identifier and extract org, repo, and normalized identifier
# Handles both PR URLs and PR numbers
# Usage: parse_pr_identifier "https://github.com/org/repo/pull/123" || parse_pr_identifier "123"
# Returns: "org|repo|pr-123" on success
parse_pr_identifier() {
    local identifier="$1"

    if [[ "$identifier" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        # Extract from URL: https://github.com/org/repo/pull/123
        local org="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local pr_num="${BASH_REMATCH[3]}"

        # Normalize org to lowercase
        org=$(echo "$org" | tr '[:upper:]' '[:lower:]')

        echo "$org|$repo|pr-$pr_num"
    elif [[ "$identifier" =~ ^[0-9]+$ ]]; then
        # Just a number - need to get org/repo from git
        local git_data
        git_data=$(get_git_org_repo 2> /dev/null || echo "unknown|unknown")
        local org="${git_data%|*}"
        local repo="${git_data#*|}"

        echo "$org|$repo|pr-$identifier"
    else
        echo "unknown|unknown|pr-$identifier"
    fi
}
