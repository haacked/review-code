#!/usr/bin/env bash
# git-context.sh - Extract git repository metadata
#
# Usage:
#   git-context.sh
#
# Output (JSON):
#   {
#     "org": "posthog",
#     "repo": "posthog",
#     "branch": "main",
#     "commit": "abc123...",
#     "working_dir": "/Users/haacked/dev/posthog/posthog",
#     "has_changes": true
#   }

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared git helper functions
source "$SCRIPT_DIR/helpers/git-helpers.sh"

get_current_commit() {
    git rev-parse HEAD
}

get_working_dir() {
    pwd
}

has_changes() {
    # Check if there are any staged or unstaged changes
    if [ -n "$(git status --porcelain)" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Main logic
main() {
    # Validate we're in a git repository
    validate_git_repo

    # Extract git context
    local git_data
    git_data=$(get_git_org_repo)
    local org="${git_data%|*}"
    local repo="${git_data#*|}"
    local branch
    branch=$(get_current_branch)
    local commit
    commit=$(get_current_commit)
    local working_dir
    working_dir=$(get_working_dir)
    local changes
    changes=$(has_changes)

    # Output JSON
    cat << EOF
{
    "org": "$org",
    "repo": "$repo",
    "branch": "$branch",
    "commit": "$commit",
    "working_dir": "$working_dir",
    "has_changes": $changes
}
EOF
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
