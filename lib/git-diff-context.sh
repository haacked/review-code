#!/usr/bin/env bash
# git-diff-context.sh - Get appropriate git diff for review
#
# Usage:
#   git-diff-context.sh
#
# Priority:
#   1. Staged changes (if any): git diff --staged
#   2. Unstaged changes (if staged is empty): git diff
#   3. Branch changes (if both above are empty): git diff main...HEAD
#
# Output:
#   Raw diff content to stdout
#   Metadata written to stderr in format: "DIFF_TYPE: staged|unstaged|branch"

# Source error helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "$SCRIPT_DIR/helpers/error-helpers.sh"

set -euo pipefail

# Validate we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    error "Not in a git repository"
    exit 1
fi

# Determine main branch (main or master)
get_main_branch() {
    if git rev-parse --verify main -- > /dev/null 2>&1; then
        echo "main"
    elif git rev-parse --verify master -- > /dev/null 2>&1; then
        echo "master"
    else
        echo "main" # Default fallback
    fi
}

# Main logic
main() {
    local diff_output=""

    # Check for staged changes
    # git diff returns 1 if no differences, which is expected
    diff_output=$(git diff --staged 2> /dev/null || test $? = 1)
    if [ -n "$diff_output" ]; then
        echo "DIFF_TYPE: staged" >&2
        echo "$diff_output"
        return 0
    fi

    # Check for unstaged changes
    diff_output=$(git diff 2> /dev/null || test $? = 1)
    if [ -n "$diff_output" ]; then
        echo "DIFF_TYPE: unstaged" >&2
        echo "$diff_output"
        return 0
    fi

    # Check for branch changes
    local main_branch
    main_branch=$(get_main_branch)
    diff_output=$(git diff "$main_branch...HEAD" 2> /dev/null || test $? = 1)
    if [ -n "$diff_output" ]; then
        echo "DIFF_TYPE: branch (compared to $main_branch)" >&2
        echo "$diff_output"
        return 0
    fi

    # No changes found
    echo "DIFF_TYPE: none" >&2
    error "No changes found (no staged, unstaged, or branch changes)"
    exit 1
}

# Main execution (only run if script is executed directly, not sourced)
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
    main "$@"
fi
