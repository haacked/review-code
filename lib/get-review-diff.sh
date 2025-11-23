#!/usr/bin/env bash
# Get diff for review based on mode
# Usage: get-review-diff.sh <mode> <mode-specific-args...> [file_pattern]

# Source error helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared exclusion patterns
source "${SCRIPT_DIR}/helpers/exclusion-patterns.sh"

# Get common exclusion patterns (minimal set for review diffs)
# shellcheck disable=SC2312  # get_exclusion_patterns failure will result in empty array
mapfile -t EXCLUSIONS < <(get_exclusion_patterns common)

# Get context lines from env or default to 1
CONTEXT_LINES="${DIFF_CONTEXT_LINES:-1}"

# Helper: Run git diff command with optional file pattern
# Args: Expects git command parts passed as separate arguments
#       $1 = git subcommand (e.g., "diff" or "show")
#       $2... = remaining git arguments (commits, ranges, etc.)
#       Second-to-last: diff description
#       Last: optional file pattern
# Sets: diff_type and diff_content global variables
run_git_diff() {
    # Extract description and pattern from end of args
    local args=("$@")
    local num_args=${#args[@]}
    local pattern="${args[$((num_args-1))]}"
    local diff_desc="${args[$((num_args-2))]}"

    # Remove description and pattern from args (keep only git command parts)
    local git_args=("${args[@]:0:$((num_args-2))}")

    # Set diff type message
    if [[ -n "${pattern}" ]] && [[ "${pattern}" != "NOPATTERN" ]]; then
        diff_type="${diff_desc} filtered by: ${pattern}"
        diff_content=$(git "${git_args[@]}" -U"${CONTEXT_LINES}" --diff-filter=d -- "${EXCLUSIONS[@]}" "${pattern}")
    else
        diff_type="${diff_desc}"
        diff_content=$(git "${git_args[@]}" -U"${CONTEXT_LINES}" --diff-filter=d -- "${EXCLUSIONS[@]}")
    fi
}

# Main execution (only run if script is executed directly, not sourced)
if [[ "${BASH_SOURCE[0]:-}" = "${0}" ]]; then
    mode="$1"
    shift

    # Extract file pattern from remaining args if present
    # It should be the last argument
    file_pattern=""
    if [[ $# -gt 0 ]]; then
        # Check if last arg looks like a file pattern (not a branch/commit)
        last_arg="${*: -1}"
        # If it contains glob (*) or looks like a path pattern (contains / or common extensions)
        # But exclude git ranges (contains ..)
        if [[ "${last_arg}" == *"*"* ]] || [[ "${last_arg}" == *"/"*.* ]]; then
            file_pattern="${last_arg}"
            # Remove last arg from positional parameters
            set -- "${@:1:$(($# - 1))}"
        fi
    fi

    # Use pattern_arg to handle empty file_pattern
    pattern_arg="${file_pattern:-NOPATTERN}"

    case "${mode}" in
        "commit")
            commit="$1"
            run_git_diff show "${commit}" --format= "commit (${commit})" "${pattern_arg}"
            ;;

        "branch")
            branch="$1"
            base_branch="$2"
            run_git_diff diff "${base_branch}..${branch}" "branch (${base_branch}..${branch})" "${pattern_arg}"
            ;;

        "range")
            range="$1"
            run_git_diff diff "${range}" "range (${range})" "${pattern_arg}"
            ;;

        "local")
            if [[ -n "${file_pattern}" ]]; then
                diff_type="local (uncommitted) filtered by: ${file_pattern}"
                # For file patterns, use git diff directly with the pattern
                # Check for staged changes first
                staged_diff=$(git diff --staged -U"${CONTEXT_LINES}" --diff-filter=d -- "${EXCLUSIONS[@]}" "${file_pattern}" 2> /dev/null || true)
                # Then unstaged changes
                unstaged_diff=$(git diff -U"${CONTEXT_LINES}" --diff-filter=d -- "${EXCLUSIONS[@]}" "${file_pattern}" 2> /dev/null || true)

                if [[ -n "${staged_diff}" ]] && [[ -n "${unstaged_diff}" ]]; then
                    diff_content="${staged_diff}
    
    --- Unstaged Changes ---
    
    ${unstaged_diff}"
                elif [[ -n "${staged_diff}" ]]; then
                    diff_content="${staged_diff}"
                elif [[ -n "${unstaged_diff}" ]]; then
                    diff_content="${unstaged_diff}"
                else
                    diff_content=""
                fi
            else
                diff_type="local (uncommitted)"
                # Use git-diff-filter.sh for local changes
                diff_content=$("${SCRIPT_DIR}/git-diff-filter.sh" 2> /dev/null || true)
            fi
            ;;

        "branch-plus-uncommitted")
            branch="$1"
            base_branch="$2"

            # Get branch diff using helper
            run_git_diff diff "${base_branch}..${branch}" "branch + uncommitted (${base_branch}..${branch} + local)" "${pattern_arg}"
            branch_diff="${diff_content}"

            # Get uncommitted diff (reuse local mode logic)
            if [[ -n "${file_pattern}" ]]; then
                staged_diff=$(git diff --staged -U"${CONTEXT_LINES}" --diff-filter=d -- "${EXCLUSIONS[@]}" "${file_pattern}" 2> /dev/null || true)
                unstaged_diff=$(git diff -U"${CONTEXT_LINES}" --diff-filter=d -- "${EXCLUSIONS[@]}" "${file_pattern}" 2> /dev/null || true)

                if [[ -n "${staged_diff}" ]] && [[ -n "${unstaged_diff}" ]]; then
                    uncommitted_diff="${staged_diff}

--- Unstaged Changes ---

${unstaged_diff}"
                elif [[ -n "${staged_diff}" ]]; then
                    uncommitted_diff="${staged_diff}"
                elif [[ -n "${unstaged_diff}" ]]; then
                    uncommitted_diff="${unstaged_diff}"
                else
                    uncommitted_diff=""
                fi
            else
                uncommitted_diff=$("${SCRIPT_DIR}/git-diff-filter.sh" 2> /dev/null || true)
            fi

            # Combine them
            diff_content="${branch_diff}

--- Uncommitted Changes ---

${uncommitted_diff}"
            ;;

        *)
            error "Unknown diff mode: ${mode}"
            exit 1
            ;;
    esac

    # Output with diff type marker
    echo "DIFF_TYPE: ${diff_type}"
    echo "${diff_content}"
fi
