#!/usr/bin/env bash
# Parse and validate /review-code command arguments
# Returns JSON with mode and validated parameters

# shellcheck disable=SC2310  # Functions in conditionals intentionally check return values
set -euo pipefail

# Get the arguments (empty string if not provided)
arg="${1:-}"
file_pattern="${2:-}"

# Check for 'find' mode - if present, strip it and set flag
FIND_MODE="false"
if [[ "${arg}" == "find" ]]; then
    FIND_MODE="true"
    # Shift arguments: second arg becomes the target, third becomes file_pattern
    arg="${2:-}"
    file_pattern="${3:-}"
fi

# Special keywords for area-specific reviews
AREA_KEYWORDS=("security" "performance" "maintainability" "testing" "compatibility" "architecture" "frontend")

# Helper: Check if argument is in array
contains() {
    local seeking=$1
    shift
    local in=0
    for element; do
        if [[ "${element}" == "${seeking}" ]]; then
            in=1
            break
        fi
    done
    echo "${in}"
}

# Helper: Check if a git ref exists
# Returns 0 if exists, 1 if not
ref_exists() {
    local ref=$1
    git rev-parse --verify --quiet "${ref}" > /dev/null 2>&1
}

# Helper: Get base branch with smart fallback
# Tries to use local branch first, falls back to remote tracking branch if needed
get_base_branch() {
    # Get the default branch name from remote origin/HEAD
    local default_branch_name
    default_branch_name=$(git symbolic-ref refs/remotes/origin/HEAD 2> /dev/null | sed 's@^refs/remotes/origin/@@')

    # If we got a default branch name, try to use it
    if [[ -n "${default_branch_name}" ]]; then
        # First try: local branch
        if ref_exists "${default_branch_name}"; then
            echo "${default_branch_name}"
            return 0
        fi

        # Second try: remote tracking branch
        if ref_exists "origin/${default_branch_name}"; then
            echo "origin/${default_branch_name}"
            return 0
        fi
    fi

    # Fallback chain: try common branch names
    # Try local "main"
    if ref_exists "main"; then
        echo "main"
        return 0
    fi

    # Try remote "origin/main"
    if ref_exists "origin/main"; then
        echo "origin/main"
        return 0
    fi

    # Try local "master"
    if ref_exists "master"; then
        echo "master"
        return 0
    fi

    # Try remote "origin/master"
    if ref_exists "origin/master"; then
        echo "origin/master"
        return 0
    fi

    # Last resort: just return "main" and let caller handle the error
    echo "main"
}

# Helper: Build JSON output with optional file_pattern and find_mode
# Usage: build_json_output mode key1 val1 [key2 val2 ...]
build_json_output() {
    local mode=$1
    shift

    local -a jq_args=("--arg" "mode" "${mode}")
    # shellcheck disable=SC2016  # $ARGS is a jq variable, not a shell variable
    local jq_filter='$ARGS.named'

    # Add all key-value pairs
    while [[ $# -gt 0 ]]; do
        local key=$1
        local val=$2
        jq_args+=("--arg" "${key}" "${val}")
        shift 2
    done

    # Add file_pattern if provided
    if [[ -n "${file_pattern}" ]]; then
        jq_args+=("--arg" "file_pattern" "${file_pattern}")
    fi

    # Add find_mode if enabled
    if [[ "${FIND_MODE}" == "true" ]]; then
        jq_args+=("--arg" "find_mode" "true")
    fi

    jq -nc "${jq_args[@]}" "${jq_filter}"
}

# Helper: Build error JSON output
build_json_error() {
    local error_msg=$1
    jq -nc --arg mode "error" --arg error "${error_msg}" \
        '{mode: $mode, error: $error}' >&2
}

# Detector: Check for area-specific review keywords
# Returns: 0 if detected (outputs JSON), 1 if not detected
detect_area_keyword() {
    [[ -z "${arg}" ]] && return 1
    # shellcheck disable=SC2312  # contains function failure is handled by return check
    [[ "$(contains "${arg}" "${AREA_KEYWORDS[@]}")" -eq 0 ]] && return 1

    build_json_output "area" "area" "${arg}"
    return 0
}

# Detector: Check for PR number or URL
# Returns: 0 if detected (outputs JSON), 1 if not detected
detect_pr() {
    [[ -z "${arg}" ]] && return 1

    # Pure digits = PR number
    if [[ "${arg}" =~ ^[0-9]+$ ]]; then
        build_json_output "pr" "pr_number" "${arg}"
        return 0
    fi

    # GitHub PR URL - extract PR number
    # Allow optional trailing path segments (e.g., /files, /commits), query params, or anchors
    if [[ "${arg}" =~ ^https://github.com/[^/]+/[^/]+/pull/([0-9]+)([/?#].*)?$ ]]; then
        local pr_number="${BASH_REMATCH[1]}"

        # Explicit validation - defense in depth
        if [[ ! "${pr_number}" =~ ^[0-9]+$ ]]; then
            build_json_error "Invalid PR number extracted from URL"
            return 1
        fi

        build_json_output "pr" "pr_number" "${pr_number}" "pr_url" "${arg}"
        return 0
    fi

    return 1
}

# Detector: Check for git range (e.g., abc123..HEAD)
# Returns: 0 if detected (outputs JSON), 1 if not detected, exits on error
detect_git_range() {
    [[ -z "${arg}" ]] && return 1
    [[ "${arg}" != *".."* ]] && return 1

    # Extract start and end refs
    local start_ref="${arg%%..*}"
    local end_ref="${arg#*..}"

    # Validate both refs exist
    if ! git rev-parse --verify "${start_ref}" -- > /dev/null 2>&1; then
        build_json_error "Invalid start ref: ${start_ref}"
        exit 1
    fi

    if ! git rev-parse --verify "${end_ref}" -- > /dev/null 2>&1; then
        build_json_error "Invalid end ref: ${end_ref}"
        exit 1
    fi

    build_json_output "range" "range" "${arg}" "start_ref" "${start_ref}" "end_ref" "${end_ref}"
    return 0
}

# Detector: Check for git ref (branch, commit, tag)
# Returns: 0 if detected (outputs JSON), 1 if not detected, exits on error
detect_git_ref() {
    [[ -z "${arg}" ]] && return 1

    # Check if it's a valid ref
    git rev-parse --verify "${arg}" -- > /dev/null 2>&1 || return 1

    # Gather ref metadata
    local ref_type
    ref_type=$(git cat-file -t "${arg}" -- 2> /dev/null || echo "unknown")

    local is_branch="false"
    if git show-ref --verify --quiet "refs/heads/${arg}" -- 2> /dev/null; then
        is_branch="true"
    fi

    local current_branch
    current_branch=$(git branch --show-current 2> /dev/null)
    # Handle detached HEAD (common in CI)
    if [[ -z "${current_branch}" ]]; then
        current_branch=$(git rev-parse --short HEAD 2> /dev/null || echo "unknown")
    fi
    local is_current="false"
    if [[ "${arg}" == "${current_branch}" ]]; then
        is_current="true"
    fi

    local base_branch
    base_branch=$(get_base_branch)

    # Handle non-ambiguous cases first
    if [[ "${is_branch}" == "true" ]] && [[ "${is_current}" == "false" ]]; then
        # Branch (not current) - review branch vs base
        build_json_output "branch" "branch" "${arg}" "base_branch" "${base_branch}" "ref_type" "${ref_type}"
        return 0
    fi

    # Determine ambiguity reason
    local ambiguous_reason=""
    if [[ "${is_current}" == "true" ]]; then
        ambiguous_reason="Current branch - unclear if reviewing uncommitted vs branch changes"
    elif [[ "${ref_type}" == "commit" ]]; then
        ambiguous_reason="Commit hash - unclear if reviewing single commit vs range to HEAD"
    elif [[ "${ref_type}" == "tag" ]]; then
        ambiguous_reason="Tag - unclear if reviewing tag vs range to HEAD"
    fi

    # Output ambiguous result
    build_json_output "ambiguous" "arg" "${arg}" "ref_type" "${ref_type}" \
        "is_branch" "${is_branch}" "is_current" "${is_current}" \
        "base_branch" "${base_branch}" "reason" "${ambiguous_reason}"
    return 0
}

# Detector: Handle no argument case (smart prompting)
# Returns: 0 always (outputs JSON or exits with error)
detect_no_arg() {
    local current_branch
    current_branch=$(git branch --show-current 2> /dev/null)
    # Handle detached HEAD (common in CI)
    if [[ -z "${current_branch}" ]]; then
        current_branch=$(git rev-parse --short HEAD 2> /dev/null || echo "unknown")
    fi
    local base_branch
    base_branch=$(get_base_branch)

    # Check for uncommitted changes
    local has_uncommitted=false
    # shellcheck disable=SC2312  # git status failure will result in empty string (correct behavior)
    if [[ -n "$(git status --porcelain)" ]]; then
        has_uncommitted=true
    fi

    # Check if on a non-base branch
    local is_feature_branch=false
    if [[ "${current_branch}" != "${base_branch}" ]]; then
        is_feature_branch=true
    fi

    # On base branch with uncommitted changes
    if [[ "${is_feature_branch}" == false ]] && [[ "${has_uncommitted}" == true ]]; then
        build_json_output "local" "scope" "uncommitted"
        return 0
    fi

    # On base branch with no uncommitted changes - error
    if [[ "${is_feature_branch}" == false ]] && [[ "${has_uncommitted}" == false ]]; then
        build_json_error "No changes to review. Use /review-code <commit|branch|range>"
        exit 1
    fi

    # On feature branch with uncommitted changes - prompt
    if [[ "${is_feature_branch}" == true ]] && [[ "${has_uncommitted}" == true ]]; then
        build_json_output "prompt" "current_branch" "${current_branch}" \
            "base_branch" "${base_branch}" "has_uncommitted" "true"
        return 0
    fi

    # On feature branch with no uncommitted changes - check for PR and remote status
    local associated_pr=""
    local remote_ahead="false"

    # Check if branch has upstream tracking
    local upstream
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2> /dev/null || echo "")

    if [[ -n "${upstream}" ]]; then
        # Check if remote is ahead of local
        local local_rev remote_rev
        local_rev=$(git rev-parse HEAD)
        remote_rev=$(git rev-parse "${upstream}" 2> /dev/null || echo "")

        if [[ -n "${remote_rev}" ]] && [[ "${local_rev}" != "${remote_rev}" ]]; then
            # Check if remote has commits we don't have, and if branches have diverged
            local behind_count ahead_count
            behind_count=$(git rev-list --count HEAD.."${upstream}" 2> /dev/null || echo "0")
            ahead_count=$(git rev-list --count "${upstream}"..HEAD 2> /dev/null || echo "0")

            if [[ "${behind_count}" -gt 0 ]]; then
                remote_ahead="true"
                if [[ "${ahead_count}" -gt 0 ]]; then
                    # Branches have diverged - warn user
                    echo "Warning: Branch '${current_branch}' has diverged from remote (local ahead by ${ahead_count}, behind by ${behind_count})" >&2
                fi
            fi
        fi
    fi

    # Check for associated PR using gh CLI
    if command -v gh > /dev/null 2>&1; then
        # Get all open PRs for this branch
        local pr_numbers
        pr_numbers=$(gh pr list --head "${current_branch}" --state open --json number --jq '.[].number' 2> /dev/null || echo "")

        if [[ -n "${pr_numbers}" ]]; then
            local pr_array
            mapfile -t pr_array <<< "${pr_numbers}"
            local pr_count="${#pr_array[@]}"

            if [[ "${pr_count}" -eq 1 ]]; then
                # Single open PR - use it
                associated_pr="${pr_array[0]}"
            elif [[ "${pr_count}" -gt 1 ]]; then
                # Multiple open PRs - pick first and warn
                associated_pr="${pr_array[0]}"
                echo "Warning: Multiple open PRs found for branch '${current_branch}': ${pr_array[*]}" >&2
                echo "Using PR #${associated_pr}. To review a different PR, specify it explicitly." >&2
            fi
        fi
    fi

    # Build output with optional PR and remote status
    local -a output_args=("branch" "branch" "${current_branch}" "base_branch" "${base_branch}" "scope" "auto")

    if [[ -n "${associated_pr}" ]]; then
        output_args+=("associated_pr" "${associated_pr}")
    fi

    if [[ "${remote_ahead}" == "true" ]]; then
        output_args+=("remote_ahead" "true")
    fi

    build_json_output "${output_args[@]}"
    return 0
}

# Main execution (only run if script is executed directly, not sourced)
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    # 1. Special Keywords (Highest Priority)
    if detect_area_keyword; then
        exit 0
    fi

    # 2. PR Detection
    if detect_pr; then
        exit 0
    fi

    # 3. Git Range Detection
    if detect_git_range; then
        exit 0
    fi

    # 4. Git Ref Detection (Requires Disambiguation)
    if detect_git_ref; then
        exit 0
    fi

    # If we have an arg but it wasn't detected, it's invalid
    if [[ -n "${arg}" ]]; then
        build_json_error "Invalid argument: ${arg}. Not a valid PR, git ref, range, or area."
        exit 1
    fi

    # 5. No Argument - Smart Prompting
    detect_no_arg
    exit 0
fi
