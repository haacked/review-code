#!/usr/bin/env bash
# review-file-path.sh - Determine review file path and metadata
#
# Usage:
#   review-file-path.sh [--org ORG] [--repo REPO] [identifier]

# Source error helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=lib/helpers/config-helpers.sh
source "${SCRIPT_DIR}/helpers/config-helpers.sh"
#
# Configuration:
#   Reads review root path from ~/.claude/review-code.env
#   Defaults to ~/dev/ai/reviews if config file doesn't exist
#
# Arguments:
#   --org ORG: GitHub organization (optional, extracts from git if not provided)
#   --repo REPO: GitHub repository (optional, extracts from git if not provided)
#   identifier: Optional identifier for the review:
#     - PR number: "123" or "pr-123"
#     - Commit: "commit-356ded2" or "356ded2"
#     - Branch: "branch-feature-name" or branch name
#     - Range: "range-abc123..HEAD"
#     - Empty: Uses current branch name
#
# Output (JSON):
#   {
#     "org": "posthog",
#     "repo": "posthog",
#     "branch": "main",
#     "pr_number": "123",
#     "file_path": "{REVIEW_ROOT_PATH}/posthog/posthog/pr-123.md",
#     "file_exists": true,
#     "needs_rename": false,
#     "old_path": null,
#     "has_branch_review": true,
#     "branch_review_path": "{REVIEW_ROOT_PATH}/posthog/posthog/my-feature.md"
#   }

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared git helper functions
source "${SCRIPT_DIR}/helpers/git-helpers.sh"

# Sanitize path component to prevent directory traversal
# This function validates and sanitizes path components with comprehensive security checks
# Returns: sanitized string on success, exits on failure
sanitize_path_component() {
    local input="$1"

    # 1. Reject empty input
    if [[ -z "${input}" ]]; then
        error "Empty path component not allowed"
        exit 1
    fi

    # 2. Reject absolute paths (starting with /)
    if [[ "${input}" == /* ]]; then
        error "Absolute paths not allowed: ${input}"
        exit 1
    fi

    # 3. Reject any path traversal patterns (containing ..)
    if [[ "${input}" =~ \.\. ]]; then
        error "Path traversal sequences not allowed: ${input}"
        exit 1
    fi

    # 4. Replace forward slashes with dashes (for branch names like haacked/feature)
    local sanitized="${input//\//-}"

    # 5. Keep only safe characters: alphanumeric, dash, underscore, dot
    sanitized=$(echo "${sanitized}" | tr -cd 'a-zA-Z0-9._-')

    # 6. Reject if starts with dot or dash (hidden files or invalid names)
    if [[ "${sanitized}" =~ ^[.-] ]]; then
        error "Path component cannot start with dot or dash: ${sanitized} (from: ${input})"
        exit 1
    fi

    # 7. Final empty check after character filtering
    if [[ -z "${sanitized}" ]]; then
        error "Path component became empty after sanitization: ${input}"
        exit 1
    fi

    echo "${sanitized}"
}

# Helper: Resolve a directory to its canonical absolute path
# Handles both existing and non-existing directories
# Args: $1 = directory path, $2 = description for error messages
# Returns: canonical path on stdout, exits on error
resolve_canonical_dir() {
    local dir="$1"
    local description="$2"

    if [[ -d "${dir}" ]]; then
        # Directory exists - resolve it directly
        if ! (cd "${dir}" 2> /dev/null && pwd -P); then
            error "Cannot resolve ${description} directory: ${dir}"
            exit 1
        fi
    else
        # Directory doesn't exist - resolve parent and append basename
        local parent
        parent=$(dirname "${dir}")
        local basename
        basename=$(basename "${dir}")

        if [[ ! -d "${parent}" ]]; then
            # Create parent directories if they don't exist
            mkdir -p "${parent}" || {
                error "Cannot create parent directory: ${parent}"
                exit 1
            }
        fi

        local canonical_parent
        canonical_parent=$(cd "${parent}" 2> /dev/null && pwd -P) || {
            error "Cannot resolve ${description} parent directory: ${parent}"
            exit 1
        }

        echo "${canonical_parent}/${basename}"
    fi
}

# Helper: Check if path is within base directory bounds
# Args: $1 = path to check, $2 = base directory that must contain it
# Returns: 0 on success, exits on failure
check_path_within_base() {
    local path="$1"
    local base="$2"

    if [[ ! "${path}" =~ ^"${base}"(/|$) ]]; then
        error "Path outside allowed directory"
        error "  Path: ${path}"
        error "  Base: ${base}"
        exit 1
    fi
}

# Verify path is within allowed directory bounds
# This prevents symlink attacks and ensures path stays within review root
# Args: $1 = path to verify, $2 = base directory that must contain the path
# Returns: 0 on success, exits on failure
verify_path_safety() {
    local path="$1"
    local base="$2"

    # Resolve base directory to canonical path
    local canonical_base
    canonical_base=$(resolve_canonical_dir "${base}" "base")

    # Resolve path directory to canonical path
    local path_dir
    path_dir=$(dirname "${path}")
    local path_file
    path_file=$(basename "${path}")

    local canonical_path
    if [[ -d "${path_dir}" ]]; then
        local canonical_dir
        canonical_dir=$(resolve_canonical_dir "${path_dir}" "path")
        canonical_path="${canonical_dir}/${path_file}"
    else
        # Directory doesn't exist yet - use as-is (already sanitized by caller)
        canonical_path="${path}"
    fi

    # Verify path is within base directory bounds
    check_path_within_base "${canonical_path}" "${canonical_base}"

    return 0
}

# Main logic
main() {
    local org=""
    local repo=""
    local identifier=""

    # Parse optional flags
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
                identifier="$1"
                shift
                ;;
        esac
    done

    # Determine if we're in a git repository
    local in_git_repo=false
    if git rev-parse --git-dir > /dev/null 2>&1; then
        in_git_repo=true
    fi

    # Extract git context if in repo and org/repo not provided
    local branch="unknown"
    local branch_raw="unknown"  # Unsanitized branch name for API calls
    if [[ "${in_git_repo}" = true ]]; then
        if [[ -z "${org}" ]] || [[ -z "${repo}" ]]; then
            local git_data
            git_data=$(get_git_org_repo)
            org="${git_data%|*}"
            repo="${git_data#*|}"
        fi
        branch_raw=$(get_current_branch)
        branch="${branch_raw}"
    elif [[ -z "${org}" ]] || [[ -z "${repo}" ]]; then
        # Not in git repo and no org/repo provided
        error "Not in a git repository and --org/--repo not provided"
        exit 1
    fi

    # Sanitize all path components to prevent directory traversal
    # Note: branch_raw is preserved unsanitized for GitHub API calls (gh pr list --head)
    org=$(sanitize_path_component "${org}")
    repo=$(sanitize_path_component "${repo}")
    branch=$(sanitize_path_component "${branch}")

    # Parse identifier to determine type and filename
    local review_type=""
    local filename=""
    local pr_number=""

    if [[ -z "${identifier}" ]]; then
        # No identifier: use branch name
        review_type="branch"
        filename="${branch}.md"
    elif [[ "${identifier}" =~ ^[0-9]+$ ]]; then
        # Pure number: PR number
        review_type="pr"
        pr_number="${identifier}"
        filename="pr-${pr_number}.md"
    elif [[ "${identifier}" =~ ^pr-([0-9]+)$ ]]; then
        # pr-123 format
        review_type="pr"
        pr_number="${BASH_REMATCH[1]}"
        filename="pr-${pr_number}.md"
    elif [[ "${identifier}" =~ ^commit-(.+)$ ]]; then
        # commit-356ded2 format
        review_type="commit"
        local commit_hash="${BASH_REMATCH[1]}"
        commit_hash=$(sanitize_path_component "${commit_hash}")
        filename="commit-${commit_hash}.md"
    elif [[ "${identifier}" =~ ^range-(.+)$ ]]; then
        # range-abc123..HEAD format
        review_type="range"
        local range="${BASH_REMATCH[1]}"
        # For ranges, replace .. with - for filename safety
        range="${range//../-to-}"
        range=$(sanitize_path_component "${range}")
        filename="range-${range}.md"
    elif [[ "${identifier}" =~ ^branch-(.+)$ ]]; then
        # branch-feature-name format
        review_type="branch"
        local branch_name="${BASH_REMATCH[1]}"
        branch_name=$(sanitize_path_component "${branch_name}")
        filename="${branch_name}.md"
    else
        # Assume it's a commit hash or branch name
        local sanitized_id
        sanitized_id=$(sanitize_path_component "${identifier}")

        # Check if it's a valid git ref (only if in git repo)
        if [[ "${in_git_repo}" = true ]] && git rev-parse --verify "${identifier}" -- > /dev/null 2>&1; then
            # Check if it's a branch
            if git show-ref --verify --quiet "refs/heads/${identifier}" -- 2> /dev/null; then
                review_type="branch"
                filename="${sanitized_id}.md"
            else
                # Assume commit
                review_type="commit"
                filename="commit-${sanitized_id}.md"
            fi
        else
            # Not a valid ref, just sanitize and use as-is
            review_type="unknown"
            filename="${sanitized_id}.md"
        fi
    fi

    # Load review root path from config, default to ~/dev/ai/reviews
    local review_root="${HOME}/dev/ai/reviews"
    if [[ -f "${HOME}/.claude/review-code.env" ]]; then
        load_config_safely "${HOME}/.claude/review-code.env"
        review_root="${REVIEW_ROOT_PATH:-${HOME}/dev/ai/reviews}"
    fi

    # Resolve review_root to canonical path to handle symlinks consistently
    # Create the directory if it doesn't exist (needed for canonical resolution)
    mkdir -p "${review_root}"
    review_root=$(resolve_canonical_dir "${review_root}" "review root")

    # Determine review directory and file path
    local review_dir="${review_root}/${org}/${repo}"
    local file_path="${review_dir}/${filename}"
    local old_path=""
    local needs_rename=false
    local file_exists=false

    # Verify paths are within allowed directory (security check)
    verify_path_safety "${review_dir}" "${review_root}"
    verify_path_safety "${file_path}" "${review_root}"

    # Check if file exists
    if [[ -f "${file_path}" ]]; then
        file_exists=true
    fi

    # For PR mode, check if old branch-based file exists
    if [[ "${review_type}" = "pr" ]] && [[ -n "${pr_number}" ]]; then
        old_path="${review_dir}/${branch}.md"
        verify_path_safety "${old_path}" "${review_root}"
        if [[ ! -f "${file_path}" ]] && [[ -f "${old_path}" ]]; then
            # Old branch-based file exists, needs rename
            file_exists=true
            needs_rename=true
        fi
    fi

    # For branch mode, always check if a PR exists and prefer PR review (only if in git repo)
    # This handles both empty identifier (current branch) and explicit branch identifiers
    # Priority: PR review > branch review (PRs are canonical review targets)
    local has_branch_review=false
    local branch_review_path=""

    if [[ "${in_git_repo}" = true ]] && [[ "${review_type}" = "branch" ]]; then
        if command -v gh &> /dev/null; then
            # Determine which branch to check - use the branch name from the identifier
            # or fall back to current branch (unsanitized for GitHub API)
            local branch_to_check="${branch_raw}"
            if [[ -n "${identifier}" ]] && [[ "${identifier}" =~ ^branch-(.+)$ ]]; then
                branch_to_check="${BASH_REMATCH[1]}"
            fi

            local pr_check
            pr_check=$(gh pr list --head "${branch_to_check}" --json number --jq '.[0].number' 2> /dev/null || echo "")
            if [[ -n "${pr_check}" ]]; then
                local pr_file="${review_dir}/pr-${pr_check}.md"
                verify_path_safety "${pr_file}" "${review_root}"

                # Check what review files exist
                local pr_review_exists=false
                local branch_review_exists=false

                if [[ -f "${pr_file}" ]]; then
                    pr_review_exists=true
                fi
                if [[ -f "${file_path}" ]]; then
                    branch_review_exists=true
                fi

                # PR review takes precedence
                if [[ "${pr_review_exists}" = true ]]; then
                    # Track if branch review also exists (for merge option)
                    if [[ "${branch_review_exists}" = true ]]; then
                        has_branch_review=true
                        branch_review_path="${file_path}"
                    fi
                    # Switch to PR review
                    pr_number="${pr_check}"
                    old_path="${file_path}"
                    file_path="${pr_file}"
                    filename="pr-${pr_number}.md"
                    review_type="pr"
                    file_exists=true
                    needs_rename=false
                elif [[ "${branch_review_exists}" = true ]]; then
                    # Only branch review exists - suggest migration to PR
                    # Keep branch file as primary, but note the PR number for migration
                    pr_number="${pr_check}"
                    needs_rename=true
                    old_path="${file_path}"
                fi
            fi
        fi
    fi

    # Ensure review directory exists
    mkdir -p "${review_dir}"

    # Output JSON using jq for safe construction
    jq -n \
        --arg org "${org}" \
        --arg repo "${repo}" \
        --arg branch "${branch}" \
        --arg pr_number "${pr_number}" \
        --arg file_path "${file_path}" \
        --argjson file_exists "${file_exists}" \
        --argjson needs_rename "${needs_rename}" \
        --arg old_path "${old_path}" \
        --argjson has_branch_review "${has_branch_review}" \
        --arg branch_review_path "${branch_review_path}" \
        '{
            org: $org,
            repo: $repo,
            branch: $branch,
            pr_number: (if $pr_number == "" then null else $pr_number end),
            file_path: $file_path,
            file_exists: $file_exists,
            needs_rename: $needs_rename,
            old_path: (if $old_path == "" then null else $old_path end),
            has_branch_review: $has_branch_review,
            branch_review_path: (if $branch_review_path == "" then null else $branch_review_path end)
        }'
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
