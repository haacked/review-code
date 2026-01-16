#!/usr/bin/env bash
# review-orchestrator.sh - Orchestrates code review workflow
#
# Usage:
#   review-orchestrator.sh [argument]
#
# Description:
#   Handles all code review workflow orchestration:
#   - Parses and validates arguments
#   - Determines review mode
#   - Gathers context and diff
#   - Outputs structured JSON for Claude to invoke agents
#
# Output:
#   JSON object with all context needed for Claude to invoke review agents

# Source error helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=lib/helpers/debug-helpers.sh
source "${SCRIPT_DIR}/helpers/debug-helpers.sh"

set -euo pipefail

# Main orchestration function
main() {
    local arg="${1:-}"
    local file_pattern="${2:-}"

    # Step 1: Parse the argument to determine mode (before debug_init to get context)
    local parse_result
    parse_result=$("${SCRIPT_DIR}/parse-review-arg.sh" "${arg}" "${file_pattern}") || {
        echo "${parse_result}" >&2
        exit 1
    }

    local mode
    mode=$(echo "${parse_result}" | jq -r '.mode')
    local pattern
    pattern=$(echo "${parse_result}" | jq -r '.file_pattern // empty')

    # Extract org/repo early for git-based modes
    # Cache git org/repo to avoid redundant operations
    local org="unknown" repo="unknown" identifier="${arg:-local}"
    local git_data=""

    # Source git helpers for all modes (needed for parse_pr_identifier)
    source "${SCRIPT_DIR}/helpers/git-helpers.sh"

    # Get git org/repo once if we're in a git repository
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git_data=$(get_git_org_repo 2> /dev/null || echo "unknown|unknown")
    fi

    case "${mode}" in
        "pr")
            # For PR mode, use helper function to parse identifier
            local pr_data
            pr_data=$(parse_pr_identifier "${identifier}")
            org="${pr_data%%|*}"
            repo=$(echo "${pr_data}" | cut -d'|' -f2)
            identifier="${pr_data##*|}"
            ;;
        "commit" | "branch" | "range" | "local" | "area" | "prompt" | "ambiguous")
            # For git-based modes, use cached git org/repo
            if [[ -n "${git_data}" ]]; then
                org="${git_data%|*}"
                repo="${git_data#*|}"
            fi
            # Set identifier based on mode
            case "${mode}" in
                "commit")
                    identifier="commit-$(echo "${parse_result}" | jq -r '.commit')"
                    ;;
                "branch")
                    identifier="branch-$(echo "${parse_result}" | jq -r '.branch')"
                    ;;
                "range")
                    identifier="range-$(echo "${parse_result}" | jq -r '.range' | tr '.' '-')"
                    ;;
                "area")
                    identifier="area-$(echo "${parse_result}" | jq -r '.area')"
                    ;;
                "local")
                    identifier="local"
                    ;;
                *)
                    # Unknown mode - should not reach here
                    identifier="unknown"
                    ;;
            esac
            ;;
        *)
            # Unknown mode
            ;;
    esac

    # Initialize debug session with actual values (no-op if DEBUG not enabled)
    debug_init "${identifier}" "${org}" "${repo}" "${mode}"
    debug_time "00-orchestrator" "start"
    debug_save "00-input" "args.txt" "arg=${arg}\nfile_pattern=${file_pattern}"

    # Save parsed results
    debug_time "01-parse" "start"
    debug_save_json "01-parse" "output.json" <<< "${parse_result}"
    debug_time "01-parse" "end"

    # Step 1.5: Handle find mode - returns early with just file info
    local find_mode
    find_mode=$(echo "${parse_result}" | jq -r '.find_mode // "false"')
    if [[ "${find_mode}" == "true" ]]; then
        handle_find_mode "${mode}" "${parse_result}" "${org}" "${repo}"
        exit 0
    fi

    # Step 2: Handle different modes
    case "${mode}" in
        "error")
            local error_msg
            error_msg=$(echo "${parse_result}" | jq -r '.error')
            echo "{\"status\":\"error\",\"message\":\"${error_msg}\"}" >&2
            exit 1
            ;;
        "ambiguous")
            # Return ambiguity info for Claude to prompt user
            echo "${parse_result}" | jq '{
                status: "ambiguous",
                arg: .arg,
                ref_type: .ref_type,
                is_branch: .is_branch,
                is_current: .is_current,
                base_branch: .base_branch,
                reason: .reason
            }'
            exit 0
            ;;
        "prompt")
            # Return prompt info for Claude to ask user
            echo "${parse_result}" | jq '{
                status: "prompt",
                current_branch: .current_branch,
                base_branch: .base_branch,
                has_uncommitted: .has_uncommitted
            }'
            exit 0
            ;;
        "area")
            local area
            area=$(echo "${parse_result}" | jq -r '.area')
            handle_local_review "${area}"
            ;;
        "pr")
            local pr_number pr_url
            pr_number=$(echo "${parse_result}" | jq -r '.pr_number // empty')
            pr_url=$(echo "${parse_result}" | jq -r '.pr_url // empty')
            if [[ -n "${pr_url}" ]]; then
                handle_pr_review "${pr_url}"
            else
                handle_pr_review "${pr_number}"
            fi
            ;;
        "commit")
            local commit
            commit=$(echo "${parse_result}" | jq -r '.commit')
            handle_commit_review "${commit}"
            ;;
        "branch")
            local branch base_branch remote_ahead associated_pr
            branch=$(echo "${parse_result}" | jq -r '.branch')
            base_branch=$(echo "${parse_result}" | jq -r '.base_branch')
            remote_ahead=$(echo "${parse_result}" | jq -r '.remote_ahead // "false"')
            associated_pr=$(echo "${parse_result}" | jq -r '.associated_pr // empty')

            # Check if remote is ahead and prompt to pull
            if [[ "${remote_ahead}" == "true" ]]; then
                echo "{\"status\":\"prompt_pull\",\"branch\":\"${branch}\",\"associated_pr\":\"${associated_pr}\"}"
                exit 0
            fi

            # Pass PR number to branch review handler
            handle_branch_review "${branch}" "${base_branch}" "${associated_pr}"
            ;;
        "range")
            local range
            range=$(echo "${parse_result}" | jq -r '.range')
            handle_range_review "${range}"
            ;;
        "local")
            handle_local_review ""
            ;;
        *)
            echo "{\"status\":\"error\",\"message\":\"Unknown mode: ${mode}\"}" >&2
            exit 1
            ;;
    esac
}

# Helper: Build file path identifier from mode and parse_result
# Args: $1 = mode, $2 = value (pr_number, branch, commit, range, or empty for current branch)
# Returns: identifier string like "pr-123", "branch-foo", "commit-abc", "range-x..y"
build_file_path_identifier() {
    local mode="$1"
    local value="$2"

    case "${mode}" in
        "pr")
            echo "pr-${value}"
            ;;
        "branch")
            echo "branch-${value}"
            ;;
        "commit")
            echo "commit-${value}"
            ;;
        "range")
            echo "range-${value}"
            ;;
        "local" | "area" | "prompt" | "ambiguous")
            # Use current branch
            local branch
            branch=$(git branch --show-current 2> /dev/null || echo "unknown")
            echo "branch-${branch}"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Common helper: Build review data from diff content
# Args: $1 = mode, $2 = diff_content, $3 = git_context, $4 = file_path_identifier, $5 = pr_context (optional), $@ = mode-specific jq args
# Returns: JSON output on stdout
build_review_data() {
    local mode="$1"
    local diff_content="$2"
    local git_context="$3"
    local file_path_identifier="$4"
    local pr_context="$5"
    shift 5
    # Remaining args are mode-specific jq --arg pairs

    # Detect languages
    local lang_info
    lang_info=$(echo "${diff_content}" | "${SCRIPT_DIR}/code-language-detect.sh")

    # Validate lang_info is valid JSON (safety check)
    if ! echo "${lang_info}" | jq empty 2> /dev/null; then
        error "Invalid JSON from code-language-detect.sh"
        exit 1
    fi

    # Extract file metadata
    local file_metadata
    file_metadata=$(echo "${diff_content}" | "${SCRIPT_DIR}/pre-review-context.sh")

    # Extract org/repo from git_context
    local org repo
    org=$(echo "${git_context}" | jq -r '.org')
    repo=$(echo "${git_context}" | jq -r '.repo')

    # Get review file path
    local file_info
    file_info=$("${SCRIPT_DIR}/review-file-path.sh" --org "${org}" --repo "${repo}" "${file_path_identifier}")

    # Load review context
    local review_context_json review_context loaded_context_files
    review_context_json=$(echo "${lang_info}" | "${SCRIPT_DIR}/load-review-context.sh" "${org}" "${repo}")
    review_context=$(echo "${review_context_json}" | jq -r '.content')
    loaded_context_files=$(echo "${review_context_json}" | jq -r '.loaded_files')

    # Build summary for user confirmation
    # Extract mode-specific fields to avoid passing large args to jq
    local mode_fields
    mode_fields=$(jq -n "$@" '$ARGS.named')
    local summary
    summary=$(build_summary "${mode}" "${diff_content}" "${git_context}" "${mode_fields}" "${pr_context}")

    # Build pre-formatted display summary for slash command
    local file_path
    file_path=$(echo "${file_info}" | jq -r '.file_path')
    local display_summary
    display_summary=$(build_display_summary "${summary}" "${file_path}" "${loaded_context_files}")

    # Output JSON for Claude with mode-specific fields
    debug_time "07-final-output" "start"
    local final_output

    # Build jq arguments - always include pr (as null if not available)
    local pr_json
    if [[ -n "${pr_context}" ]]; then
        pr_json="${pr_context}"
    else
        pr_json="null"
    fi

    local -a jq_args=(
        -n
        --arg mode "${mode}"
        --argjson git "${git_context}"
        --arg diff "${diff_content}"
        --argjson lang "${lang_info}"
        --argjson meta "${file_metadata}"
        --argjson file "${file_info}"
        --arg context "${review_context}"
        --argjson summary "${summary}"
        --arg display "${display_summary}"
        --argjson pr "${pr_json}"
    )

    # Add mode-specific arguments
    jq_args+=("$@")

    # Single jq invocation with conditional pr field
    final_output=$(jq "${jq_args[@]}" \
        '{
            status: "ready",
            mode: $mode,
            git: $git,
            diff: $diff,
            languages: $lang,
            file_metadata: $meta,
            file_info: $file,
            review_context: $context,
            summary: $summary,
            display_summary: $display,
            next_step: "gather_architectural_context"
        }
        + (if $pr != null then {pr: $pr} else {} end)
        + ($ARGS.named | with_entries(select(.key | startswith("mode_"))) | with_entries(.key |= sub("^mode_"; "")))')
    debug_save_json "07-final-output" "output.json" <<< "${final_output}"
    debug_time "07-final-output" "end"
    debug_time "00-orchestrator" "end"
    debug_finalize

    echo "${final_output}"
}

# Build a pre-formatted display summary for the slash command
# Args: $1 = summary_json, $2 = file_path, $3 = loaded_context_files (optional, JSON array)
# Returns: Markdown-formatted text ready to display
build_display_summary() {
    local summary_json="$1"
    local file_path="$2"
    local loaded_context_files="${3:-[]}"

    local mode
    mode=$(echo "${summary_json}" | jq -r '.mode')

    local output=""

    case "${mode}" in
        "branch")
            local repo branch base_branch commit working_dir comparison commits files added removed
            repo=$(echo "${summary_json}" | jq -r '.repository')
            branch=$(echo "${summary_json}" | jq -r '.branch')
            base_branch=$(echo "${summary_json}" | jq -r '.base_branch')
            commit=$(echo "${summary_json}" | jq -r '.commit')
            working_dir=$(echo "${summary_json}" | jq -r '.working_directory')
            comparison=$(echo "${summary_json}" | jq -r '.comparison')
            commits=$(echo "${summary_json}" | jq -r '.stats.commits')
            files=$(echo "${summary_json}" | jq -r '.stats.files_changed')
            added=$(echo "${summary_json}" | jq -r '.stats.lines_added')
            removed=$(echo "${summary_json}" | jq -r '.stats.lines_removed')

            output="Review Summary

Repository: ${repo}
Branch: ${branch} (vs ${base_branch})
Commit: ${commit:0:10}
Location: ${working_dir}
Comparison: ${comparison}
"

            # Check for associated PR
            local has_pr
            has_pr=$(echo "${summary_json}" | jq -r '.associated_pr // empty')
            if [[ -n "${has_pr}" ]]; then
                local pr_number pr_title pr_url pr_author pr_state
                pr_number=$(echo "${summary_json}" | jq -r '.associated_pr.number')
                pr_title=$(echo "${summary_json}" | jq -r '.associated_pr.title')
                pr_url=$(echo "${summary_json}" | jq -r '.associated_pr.url')
                pr_author=$(echo "${summary_json}" | jq -r '.associated_pr.author')
                pr_state=$(echo "${summary_json}" | jq -r '.associated_pr.state')

                output="${output}
Associated PR: #${pr_number} - ${pr_title}
Author: ${pr_author} | State: ${pr_state}
URL: ${pr_url}
"
            fi

            output="${output}
Changes:
- Commits: ${commits}
- Files: ${files}
- Added: +${added} lines
- Removed: -${removed} lines"
            ;;

        "pr")
            local repo pr_number pr_title pr_url branch working_dir files added removed
            repo=$(echo "${summary_json}" | jq -r '.repository')
            pr_number=$(echo "${summary_json}" | jq -r '.pr_number')
            pr_title=$(echo "${summary_json}" | jq -r '.pr_title')
            pr_url=$(echo "${summary_json}" | jq -r '.pr_url')
            branch=$(echo "${summary_json}" | jq -r '.branch')
            working_dir=$(echo "${summary_json}" | jq -r '.working_directory // empty')
            files=$(echo "${summary_json}" | jq -r '.stats.files_changed')
            added=$(echo "${summary_json}" | jq -r '.stats.lines_added')
            removed=$(echo "${summary_json}" | jq -r '.stats.lines_removed')

            output="Review Summary

Repository: ${repo}
PR: #${pr_number} - ${pr_title}
URL: ${pr_url}
Branch: ${branch}"

            # Include location only if we have a local checkout (fast path)
            if [[ -n "${working_dir}" ]]; then
                output="${output}
Location: ${working_dir}"
            fi

            output="${output}

Changes:
- Files: ${files}
- Added: +${added} lines
- Removed: -${removed} lines"
            ;;

        "commit")
            local repo commit working_dir files added removed
            repo=$(echo "${summary_json}" | jq -r '.repository')
            commit=$(echo "${summary_json}" | jq -r '.commit')
            working_dir=$(echo "${summary_json}" | jq -r '.working_directory')
            files=$(echo "${summary_json}" | jq -r '.stats.files_changed')
            added=$(echo "${summary_json}" | jq -r '.stats.lines_added')
            removed=$(echo "${summary_json}" | jq -r '.stats.lines_removed')

            output="Review Summary

Repository: ${repo}
Commit: ${commit}
Location: ${working_dir}

Changes:
- Files: ${files}
- Added: +${added} lines
- Removed: -${removed} lines"
            ;;

        "range")
            local repo range working_dir commits files added removed
            repo=$(echo "${summary_json}" | jq -r '.repository')
            range=$(echo "${summary_json}" | jq -r '.range')
            working_dir=$(echo "${summary_json}" | jq -r '.working_directory')
            commits=$(echo "${summary_json}" | jq -r '.stats.commits')
            files=$(echo "${summary_json}" | jq -r '.stats.files_changed')
            added=$(echo "${summary_json}" | jq -r '.stats.lines_added')
            removed=$(echo "${summary_json}" | jq -r '.stats.lines_removed')

            output="Review Summary

Repository: ${repo}
Range: ${range}
Location: ${working_dir}

Changes:
- Commits: ${commits}
- Files: ${files}
- Added: +${added} lines
- Removed: -${removed} lines"
            ;;

        "local")
            local repo branch working_dir area files added removed
            repo=$(echo "${summary_json}" | jq -r '.repository')
            branch=$(echo "${summary_json}" | jq -r '.branch')
            working_dir=$(echo "${summary_json}" | jq -r '.working_directory')
            area=$(echo "${summary_json}" | jq -r '.review_area // "all"')
            files=$(echo "${summary_json}" | jq -r '.stats.files_changed')
            added=$(echo "${summary_json}" | jq -r '.stats.lines_added')
            removed=$(echo "${summary_json}" | jq -r '.stats.lines_removed')

            output="Review Summary

Repository: ${repo}
Branch: ${branch} (uncommitted changes)
Location: ${working_dir}
Review Area: ${area}

Changes:
- Files: ${files}
- Added: +${added} lines
- Removed: -${removed} lines"
            ;;

        *)
            output="Review Summary

Unknown mode: ${mode}"
            ;;
    esac

    # Add loaded context files section if any were loaded
    local context_count
    context_count=$(echo "${loaded_context_files}" | jq -r 'length // 0')
    if [[ "${context_count}" -gt 0 ]]; then
        output="${output}

Context files loaded:"
        # Format each file as a bullet point
        while IFS= read -r context_file; do
            output="${output}
- ${context_file}"
        done < <(echo "${loaded_context_files}" | jq -r '.[]' || true)
    fi

    # Add final line
    output="${output}

Review will be saved to: ${file_path}"

    echo "${output}"
}

# Build a human-readable summary for user confirmation
# Args: $1 = mode, $2 = diff_content, $3 = git_context, $4 = mode_fields (JSON string), $5 = pr_context (optional)
build_summary() {
    local mode="$1"
    local diff_content="$2"
    local git_context="$3"
    local mode_fields="$4"
    local pr_context="${5:-}"

    # Extract key info from git context
    local org repo branch commit working_dir
    org=$(echo "${git_context}" | jq -r '.org')
    repo=$(echo "${git_context}" | jq -r '.repo')
    branch=$(echo "${git_context}" | jq -r '.branch // "unknown"')
    commit=$(echo "${git_context}" | jq -r '.commit // "unknown"')
    working_dir=$(echo "${git_context}" | jq -r '.working_dir // "unknown"')

    # Calculate diff stats
    local files_changed lines_added lines_removed
    files_changed=$(echo "${diff_content}" | grep -cE '^diff --git')
    lines_added=$(echo "${diff_content}" | grep -E '^\+' | grep -vcE '^\+\+\+')
    lines_removed=$(echo "${diff_content}" | grep -E '^-' | grep -vcE '^---')

    # Parse mode-specific fields (already in JSON format)
    local parsed_args="${mode_fields}"

    # Build mode-specific summary
    case "${mode}" in
        "branch")
            local target_branch base_branch
            target_branch=$(echo "${parsed_args}" | jq -r '.mode_branch // "unknown"')
            base_branch=$(echo "${parsed_args}" | jq -r '.mode_base_branch // "unknown"')

            # Count commits in branch
            local commit_count
            commit_count=$(git rev-list --count "${base_branch}..${target_branch}" 2> /dev/null || echo "unknown")

            # Extract PR fields if context available
            local pr_number="" pr_title="" pr_url="" pr_author="" pr_state=""
            if [[ -n "${pr_context}" ]]; then
                pr_number=$(echo "${pr_context}" | jq -r '.number // ""')
                pr_title=$(echo "${pr_context}" | jq -r '.title // ""')
                pr_url=$(echo "${pr_context}" | jq -r '.url // ""')
                pr_author=$(echo "${pr_context}" | jq -r '.author // ""')
                pr_state=$(echo "${pr_context}" | jq -r '.state // ""')
            fi

            # Build jq arguments - always include all fields (empty if not available)
            local -a summary_args=(
                -n
                --arg mode "${mode}"
                --arg org "${org}"
                --arg repo "${repo}"
                --arg branch "${target_branch}"
                --arg base_branch "${base_branch}"
                --arg commit "${commit}"
                --arg working_dir "${working_dir}"
                --arg files "${files_changed}"
                --arg added "${lines_added}"
                --arg removed "${lines_removed}"
                --arg commits "${commit_count}"
                --arg pr_number "${pr_number}"
                --arg pr_title "${pr_title}"
                --arg pr_url "${pr_url}"
                --arg pr_author "${pr_author}"
                --arg pr_state "${pr_state}"
            )

            # Single jq invocation with conditional PR field
            jq "${summary_args[@]}" \
                '{
                    mode: $mode,
                    repository: "\($org)/\($repo)",
                    branch: $branch,
                    base_branch: $base_branch,
                    commit: $commit,
                    working_directory: $working_dir,
                    comparison: "\($base_branch)..\($branch)",
                    stats: {
                        commits: $commits,
                        files_changed: $files,
                        lines_added: $added,
                        lines_removed: $removed
                    }
                }
                + (if ($pr_number != null and $pr_number != "") then {
                    associated_pr: {
                        number: $pr_number,
                        title: $pr_title,
                        url: $pr_url,
                        author: $pr_author,
                        state: $pr_state
                    }
                } else {} end)'
            ;;
        "commit")
            local target_commit
            target_commit=$(echo "${parsed_args}" | jq -r '.mode_commit // "unknown"')
            jq -n \
                --arg mode "${mode}" \
                --arg org "${org}" \
                --arg repo "${repo}" \
                --arg commit "${target_commit}" \
                --arg working_dir "${working_dir}" \
                --arg files "${files_changed}" \
                --arg added "${lines_added}" \
                --arg removed "${lines_removed}" \
                '{
                    mode: $mode,
                    repository: "\($org)/\($repo)",
                    commit: $commit,
                    working_directory: $working_dir,
                    stats: {
                        files_changed: $files,
                        lines_added: $added,
                        lines_removed: $removed
                    }
                }'
            ;;
        "range")
            local target_range
            target_range=$(echo "${parsed_args}" | jq -r '.mode_range // "unknown"')

            # Count commits in range
            local commit_count
            commit_count=$(git rev-list --count "${target_range}" 2> /dev/null || echo "unknown")

            jq -n \
                --arg mode "${mode}" \
                --arg org "${org}" \
                --arg repo "${repo}" \
                --arg range "${target_range}" \
                --arg working_dir "${working_dir}" \
                --arg files "${files_changed}" \
                --arg added "${lines_added}" \
                --arg removed "${lines_removed}" \
                --arg commits "${commit_count}" \
                '{
                    mode: $mode,
                    repository: "\($org)/\($repo)",
                    range: $range,
                    working_directory: $working_dir,
                    stats: {
                        commits: $commits,
                        files_changed: $files,
                        lines_added: $added,
                        lines_removed: $removed
                    }
                }'
            ;;
        "local")
            local area
            area=$(echo "${parsed_args}" | jq -r '.mode_area // "all"')
            jq -n \
                --arg mode "${mode}" \
                --arg org "${org}" \
                --arg repo "${repo}" \
                --arg branch "${branch}" \
                --arg working_dir "${working_dir}" \
                --arg area "${area}" \
                --arg files "${files_changed}" \
                --arg added "${lines_added}" \
                --arg removed "${lines_removed}" \
                '{
                    mode: $mode,
                    repository: "\($org)/\($repo)",
                    branch: $branch,
                    working_directory: $working_dir,
                    review_area: $area,
                    stats: {
                        files_changed: $files,
                        lines_added: $added,
                        lines_removed: $removed
                    }
                }'
            ;;
        "pr")
            # Extract PR fields from pr_context
            local pr_number pr_title pr_url pr_branch
            pr_number=$(echo "${pr_context}" | jq -r '.number // "unknown"')
            pr_title=$(echo "${pr_context}" | jq -r '.title // "unknown"')
            pr_url=$(echo "${pr_context}" | jq -r '.url // "unknown"')
            pr_branch=$(echo "${parsed_args}" | jq -r '.mode_branch // "unknown"')

            # Include working_directory only if we have a meaningful local path (fast path)
            jq -n \
                --arg mode "${mode}" \
                --arg org "${org}" \
                --arg repo "${repo}" \
                --arg pr_number "${pr_number}" \
                --arg pr_title "${pr_title}" \
                --arg pr_url "${pr_url}" \
                --arg branch "${pr_branch}" \
                --arg working_dir "${working_dir}" \
                --arg files "${files_changed}" \
                --arg added "${lines_added}" \
                --arg removed "${lines_removed}" \
                '{
                    mode: $mode,
                    repository: "\($org)/\($repo)",
                    pr_number: $pr_number,
                    pr_title: $pr_title,
                    pr_url: $pr_url,
                    branch: $branch,
                    stats: {
                        files_changed: $files,
                        lines_added: $added,
                        lines_removed: $removed
                    }
                }
                + (if $working_dir != "null" and $working_dir != "" then {working_directory: $working_dir} else {} end)'
            ;;
        *)
            jq -n \
                --arg mode "${mode}" \
                --arg org "${org}" \
                --arg repo "${repo}" \
                --arg working_dir "${working_dir}" \
                --arg files "${files_changed}" \
                --arg added "${lines_added}" \
                --arg removed "${lines_removed}" \
                '{
                    mode: $mode,
                    repository: "\($org)/\($repo)",
                    working_directory: $working_dir,
                    stats: {
                        files_changed: $files,
                        lines_added: $added,
                        lines_removed: $removed
                    }
                }'
            ;;
    esac
}

# Handle find mode - returns file info without running full review
# Args: $1 = mode, $2 = parse_result, $3 = org, $4 = repo
handle_find_mode() {
    local mode="$1"
    local parse_result="$2"
    local org="$3"
    local repo="$4"

    # Handle errors
    if [[ "${mode}" == "error" ]]; then
        echo "${parse_result}" | jq '{status: "error", message: .error}' >&2
        return
    fi

    # For PR mode with just a number, get org/repo from git context
    if [[ "${mode}" == "pr" ]] && [[ "${org}" == "unknown" ]] && git rev-parse --git-dir > /dev/null 2>&1; then
        local git_data
        git_data=$(get_git_org_repo 2> /dev/null || echo "unknown|unknown")
        org="${git_data%|*}"
        repo="${git_data#*|}"
    fi

    # Extract value from parse_result based on mode
    local value=""
    case "${mode}" in
        "pr") value=$(echo "${parse_result}" | jq -r '.pr_number') ;;
        "branch") value=$(echo "${parse_result}" | jq -r '.branch') ;;
        "commit") value=$(echo "${parse_result}" | jq -r '.commit') ;;
        "range") value=$(echo "${parse_result}" | jq -r '.range') ;;
    esac

    # Use shared helper to build identifier
    local file_path_identifier
    file_path_identifier=$(build_file_path_identifier "${mode}" "${value}")

    if [[ -z "${file_path_identifier}" ]]; then
        echo "{\"status\":\"error\",\"message\":\"Find mode not supported for mode: ${mode}\"}" >&2
        return
    fi

    # Build display target from the mode and value
    local display_target
    case "${mode}" in
        "pr") display_target="PR #${value}" ;;
        "branch") display_target="branch ${value}" ;;
        "commit") display_target="commit ${value}" ;;
        "range") display_target="range ${value}" ;;
        *) display_target="current branch $(git branch --show-current 2> /dev/null || echo unknown)" ;;
    esac

    # Get file info from review-file-path.sh (handles PR association, existence, etc.)
    local file_info file_exists
    file_info=$("${SCRIPT_DIR}/review-file-path.sh" --org "${org}" --repo "${repo}" "${file_path_identifier}")
    file_exists=$(echo "${file_info}" | jq -r '.file_exists')

    # Update display if review-file-path.sh found an associated PR
    local found_pr
    found_pr=$(echo "${file_info}" | jq -r '.pr_number // empty')
    if [[ -n "${found_pr}" ]] && [[ "${mode}" != "pr" ]]; then
        display_target="${display_target} (PR #${found_pr})"
    fi

    # Read file summary if exists
    local file_path file_summary=""
    file_path=$(echo "${file_info}" | jq -r '.file_path')
    if [[ "${file_exists}" == "true" ]] && [[ -f "${file_path}" ]]; then
        file_summary=$(head -50 "${file_path}" 2> /dev/null || echo "")
    fi

    # Output result
    jq -n \
        --arg status "find" \
        --argjson file_info "${file_info}" \
        --arg display_target "${display_target}" \
        --arg file_summary "${file_summary}" \
        '{status: $status, file_info: $file_info, display_target: $display_target, file_summary: $file_summary}'
}

# Handle PR review
handle_pr_review() {
    local pr_identifier="$1"

    # Fetch PR data
    local pr_data
    pr_data=$("${SCRIPT_DIR}/pr-context.sh" "${pr_identifier}")

    local pr_number org repo head_ref
    pr_number=$(echo "${pr_data}" | jq -r '.number')
    org=$(echo "${pr_data}" | jq -r '.org')
    repo=$(echo "${pr_data}" | jq -r '.repo')
    head_ref=$(echo "${pr_data}" | jq -r '.head_ref')

    # Check if we're on the matching branch (enables richer local context)
    # Conditions: in a git repo, repo matches PR's repo, branch matches PR's head branch
    local git_context=""

    if git rev-parse --git-dir > /dev/null 2>&1; then
        source "${SCRIPT_DIR}/helpers/git-helpers.sh"

        local current_git_data
        current_git_data=$(get_git_org_repo 2> /dev/null || echo "|")
        local current_org="${current_git_data%|*}"
        local current_repo="${current_git_data#*|}"
        local current_branch
        current_branch=$(git branch --show-current 2> /dev/null || echo "")

        # Normalize org names to lowercase for comparison
        current_org=$(echo "${current_org}" | tr '[:upper:]' '[:lower:]')

        if [[ "${current_org}" = "${org}" ]] && [[ "${current_repo}" = "${repo}" ]] && [[ "${current_branch}" = "${head_ref}" ]]; then
            git_context=$("${SCRIPT_DIR}/git-context.sh")
        fi
    fi

    # If not on fast path, construct a synthetic git_context with PR's org/repo
    # Note: working_dir is null when not on fast path (no meaningful local directory)
    if [[ -z "${git_context}" ]]; then
        git_context=$(jq -n \
            --arg org "${org}" \
            --arg repo "${repo}" \
            --arg branch "${head_ref}" \
            '{
                org: $org,
                repo: $repo,
                branch: $branch,
                commit: null,
                working_dir: null,
                has_changes: false
            }')
    fi

    # Extract diff content from PR data
    local diff_content
    diff_content=$(echo "${pr_data}" | jq -r '.diff')

    build_review_data "pr" "${diff_content}" "${git_context}" "pr-${pr_number}" "${pr_data}" \
        --arg mode_branch "${head_ref}"
}

# Handle commit review
handle_commit_review() {
    local commit="$1"

    # Get git context
    local git_context
    git_context=$("${SCRIPT_DIR}/git-context.sh")

    # Get diff for commit
    local diff_content
    if [[ -n "${pattern}" ]]; then
        diff_content=$("${SCRIPT_DIR}/get-review-diff.sh" commit "${commit}" "${pattern}")
    else
        diff_content=$("${SCRIPT_DIR}/get-review-diff.sh" commit "${commit}")
    fi

    # Use common helper to build review data
    build_review_data "commit" "${diff_content}" "${git_context}" "commit-${commit}" "" \
        --arg mode_commit "${commit}"
}

# Handle branch review
handle_branch_review() {
    local branch="$1"
    local base_branch="$2"
    local associated_pr="${3:-}"

    # Get git context
    local git_context
    git_context=$("${SCRIPT_DIR}/git-context.sh")

    # Fetch PR context if available
    local pr_context=""
    if [[ -n "${associated_pr}" ]]; then
        pr_context=$("${SCRIPT_DIR}/pr-context.sh" "${associated_pr}" 2>&1 || true)
        if [[ -z "${pr_context}" ]] || ! echo "${pr_context}" | jq empty 2> /dev/null; then
            echo "Warning: Failed to fetch PR context for PR #${associated_pr}" >&2
            pr_context=""
        fi
    fi

    # Get diff for branch
    local diff_content
    if [[ -n "${pattern}" ]]; then
        diff_content=$("${SCRIPT_DIR}/get-review-diff.sh" branch "${branch}" "${base_branch}" "${pattern}")
    else
        diff_content=$("${SCRIPT_DIR}/get-review-diff.sh" branch "${branch}" "${base_branch}")
    fi

    # Use common helper to build review data
    # Build argument array conditionally
    local -a build_args=(
        "branch"
        "${diff_content}"
        "${git_context}"
        "branch-${branch}"
        "${pr_context}"
        --arg mode_branch "${branch}"
        --arg mode_base_branch "${base_branch}"
    )

    # Add associated PR argument only if PR context exists
    if [[ -n "${associated_pr}" ]]; then
        build_args+=(--arg mode_associated_pr "${associated_pr}")
    fi

    build_review_data "${build_args[@]}"
}

# Handle range review
handle_range_review() {
    local range="$1"

    # Get git context
    local git_context
    git_context=$("${SCRIPT_DIR}/git-context.sh")

    # Get diff for range
    local diff_content
    if [[ -n "${pattern}" ]]; then
        diff_content=$("${SCRIPT_DIR}/get-review-diff.sh" range "${range}" "${pattern}")
    else
        diff_content=$("${SCRIPT_DIR}/get-review-diff.sh" range "${range}")
    fi

    # Use common helper to build review data
    build_review_data "range" "${diff_content}" "${git_context}" "range-${range}" "" \
        --arg mode_range "${range}"
}

# Handle local review (uncommitted changes)
handle_local_review() {
    local area="$1" # Optional: security, performance, etc. or empty for all

    # Get git context
    local git_context
    git_context=$("${SCRIPT_DIR}/git-context.sh")

    # Get diff for local changes
    local diff_content
    if [[ -n "${pattern}" ]]; then
        diff_content=$("${SCRIPT_DIR}/get-review-diff.sh" local "${pattern}")
    else
        diff_content=$("${SCRIPT_DIR}/get-review-diff.sh" local)
    fi

    # Check if there are actually changes
    if echo "${diff_content}" | grep -q "^Error: No changes found"; then
        echo "{\"status\":\"error\",\"message\":\"No changes found (no staged, unstaged, or branch changes)\"}" >&2
        exit 1
    fi

    # Use common helper to build review data
    if [[ -n "${area}" ]]; then
        build_review_data "local" "${diff_content}" "${git_context}" "" "" \
            --arg mode_area "${area}"
    else
        build_review_data "local" "${diff_content}" "${git_context}" "" ""
    fi
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
