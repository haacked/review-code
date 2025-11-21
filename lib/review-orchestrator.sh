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
source "$SCRIPT_DIR/helpers/error-helpers.sh"
# shellcheck source=lib/helpers/debug-helpers.sh
source "$SCRIPT_DIR/helpers/debug-helpers.sh"

set -euo pipefail

# Main orchestration function
main() {
    local arg="${1:-}"
    local file_pattern="${2:-}"

    # Step 1: Parse the argument to determine mode (before debug_init to get context)
    local parse_result
    parse_result=$("$SCRIPT_DIR/parse-review-arg.sh" "$arg" "$file_pattern") || {
        echo "$parse_result" >&2
        exit 1
    }

    local mode
    mode=$(echo "$parse_result" | jq -r '.mode')
    local pattern
    pattern=$(echo "$parse_result" | jq -r '.file_pattern // empty')

    # Extract org/repo early for git-based modes
    # Cache git org/repo to avoid redundant operations
    local org="unknown" repo="unknown" identifier="${arg:-local}"
    local git_data=""

    # Source git helpers for all modes (needed for parse_pr_identifier)
    source "$SCRIPT_DIR/helpers/git-helpers.sh"

    # Get git org/repo once if we're in a git repository
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git_data=$(get_git_org_repo 2> /dev/null || echo "unknown|unknown")
    fi

    case "$mode" in
        "pr")
            # For PR mode, use helper function to parse identifier
            local pr_data
            pr_data=$(parse_pr_identifier "$identifier")
            org="${pr_data%%|*}"
            repo=$(echo "$pr_data" | cut -d'|' -f2)
            identifier="${pr_data##*|}"
            ;;
        "commit" | "branch" | "range" | "local" | "area")
            # For git-based modes, use cached git org/repo
            if [ -n "$git_data" ]; then
                org="${git_data%|*}"
                repo="${git_data#*|}"
            fi
            # Set identifier based on mode
            case "$mode" in
                "commit")
                    identifier="commit-$(echo "$parse_result" | jq -r '.commit')"
                    ;;
                "branch")
                    identifier="branch-$(echo "$parse_result" | jq -r '.branch')"
                    ;;
                "range")
                    identifier="range-$(echo "$parse_result" | jq -r '.range' | tr '.' '-')"
                    ;;
                "area")
                    identifier="area-$(echo "$parse_result" | jq -r '.area')"
                    ;;
                "local")
                    identifier="local"
                    ;;
            esac
            ;;
    esac

    # Initialize debug session with actual values (no-op if DEBUG not enabled)
    debug_init "$identifier" "$org" "$repo" "$mode"
    debug_time "00-orchestrator" "start"
    debug_save "00-input" "args.txt" "arg=$arg\nfile_pattern=$file_pattern"

    # Save parsed results
    debug_time "01-parse" "start"
    debug_save_json "01-parse" "output.json" <<< "$parse_result"
    debug_time "01-parse" "end"

    # Step 2: Handle different modes
    case "$mode" in
        "error")
            local error_msg
            error_msg=$(echo "$parse_result" | jq -r '.error')
            echo "{\"status\":\"error\",\"message\":\"$error_msg\"}" >&2
            exit 1
            ;;
        "ambiguous")
            # Return ambiguity info for Claude to prompt user
            echo "$parse_result" | jq '{
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
            echo "$parse_result" | jq '{
                status: "prompt",
                current_branch: .current_branch,
                base_branch: .base_branch,
                has_uncommitted: .has_uncommitted
            }'
            exit 0
            ;;
        "area")
            local area
            area=$(echo "$parse_result" | jq -r '.area')
            handle_local_review "$area"
            ;;
        "pr")
            local pr_number pr_url
            pr_number=$(echo "$parse_result" | jq -r '.pr_number // empty')
            pr_url=$(echo "$parse_result" | jq -r '.pr_url // empty')
            if [ -n "$pr_url" ]; then
                handle_pr_review "$pr_url"
            else
                handle_pr_review "$pr_number"
            fi
            ;;
        "commit")
            local commit
            commit=$(echo "$parse_result" | jq -r '.commit')
            handle_commit_review "$commit"
            ;;
        "branch")
            local branch base_branch remote_ahead associated_pr
            branch=$(echo "$parse_result" | jq -r '.branch')
            base_branch=$(echo "$parse_result" | jq -r '.base_branch')
            remote_ahead=$(echo "$parse_result" | jq -r '.remote_ahead // "false"')
            associated_pr=$(echo "$parse_result" | jq -r '.associated_pr // empty')

            # Check if remote is ahead and prompt to pull
            if [ "$remote_ahead" == "true" ]; then
                echo "{\"status\":\"prompt_pull\",\"branch\":\"$branch\",\"associated_pr\":\"$associated_pr\"}"
                exit 0
            fi

            # Pass PR number to branch review handler
            handle_branch_review "$branch" "$base_branch" "$associated_pr"
            ;;
        "range")
            local range
            range=$(echo "$parse_result" | jq -r '.range')
            handle_range_review "$range"
            ;;
        "local")
            handle_local_review ""
            ;;
        *)
            echo "{\"status\":\"error\",\"message\":\"Unknown mode: $mode\"}" >&2
            exit 1
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
    lang_info=$(echo "$diff_content" | "$SCRIPT_DIR/code-language-detect.sh")

    # Extract file metadata
    local file_metadata
    file_metadata=$(echo "$diff_content" | "$SCRIPT_DIR/pre-review-context.sh")

    # Get review file path
    local file_info
    file_info=$("$SCRIPT_DIR/review-file-path.sh" "$file_path_identifier")

    # Load review context
    local org repo review_context
    org=$(echo "$git_context" | jq -r '.org')
    repo=$(echo "$git_context" | jq -r '.repo')
    review_context=$(echo "$lang_info" | "$SCRIPT_DIR/load-review-context.sh" "$org" "$repo")

    # Build summary for user confirmation
    # Extract mode-specific fields to avoid passing large args to jq
    local mode_fields
    mode_fields=$(jq -n "$@" '$ARGS.named')
    local summary
    summary=$(build_summary "$mode" "$diff_content" "$git_context" "$mode_fields" "$pr_context")

    # Output JSON for Claude with mode-specific fields
    debug_time "07-final-output" "start"
    local final_output
    if [ -n "$pr_context" ]; then
        final_output=$(jq -n \
            --arg mode "$mode" \
            --argjson git "$git_context" \
            --arg diff "$diff_content" \
            --argjson lang "$lang_info" \
            --argjson meta "$file_metadata" \
            --argjson file "$file_info" \
            --arg context "$review_context" \
            --argjson summary "$summary" \
            --argjson pr "$pr_context" \
            "$@" \
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
                pr: $pr,
                next_step: "gather_architectural_context"
            } + ($ARGS.named | with_entries(select(.key | startswith("mode_"))) | with_entries(.key |= sub("^mode_"; "")))')
    else
        final_output=$(jq -n \
            --arg mode "$mode" \
            --argjson git "$git_context" \
            --arg diff "$diff_content" \
            --argjson lang "$lang_info" \
            --argjson meta "$file_metadata" \
            --argjson file "$file_info" \
            --arg context "$review_context" \
            --argjson summary "$summary" \
            "$@" \
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
                next_step: "gather_architectural_context"
            } + ($ARGS.named | with_entries(select(.key | startswith("mode_"))) | with_entries(.key |= sub("^mode_"; "")))')
    fi
    debug_save_json "07-final-output" "output.json" <<< "$final_output"
    debug_time "07-final-output" "end"
    debug_time "00-orchestrator" "end"
    debug_finalize

    echo "$final_output"
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
    org=$(echo "$git_context" | jq -r '.org')
    repo=$(echo "$git_context" | jq -r '.repo')
    branch=$(echo "$git_context" | jq -r '.branch // "unknown"')
    commit=$(echo "$git_context" | jq -r '.commit // "unknown"')
    working_dir=$(echo "$git_context" | jq -r '.working_dir // "unknown"')

    # Calculate diff stats
    local files_changed lines_added lines_removed
    files_changed=$(echo "$diff_content" | grep -E '^diff --git' | wc -l | tr -d ' ')
    lines_added=$(echo "$diff_content" | grep -E '^\+' | grep -v -E '^\+\+\+' | wc -l | tr -d ' ')
    lines_removed=$(echo "$diff_content" | grep -E '^-' | grep -v -E '^---' | wc -l | tr -d ' ')

    # Parse mode-specific fields (already in JSON format)
    local parsed_args="$mode_fields"

    # Build mode-specific summary
    case "$mode" in
        "branch")
            local target_branch base_branch
            target_branch=$(echo "$parsed_args" | jq -r '.mode_branch // "unknown"')
            base_branch=$(echo "$parsed_args" | jq -r '.mode_base_branch // "unknown"')

            # Count commits in branch
            local commit_count
            commit_count=$(git rev-list --count "${base_branch}..${target_branch}" 2> /dev/null || echo "unknown")

            # Build base summary
            if [ -n "$pr_context" ]; then
                # Include PR information
                local pr_number pr_title pr_url pr_author pr_state
                pr_number=$(echo "$pr_context" | jq -r '.number // "unknown"')
                pr_title=$(echo "$pr_context" | jq -r '.title // "unknown"')
                pr_url=$(echo "$pr_context" | jq -r '.url // "unknown"')
                pr_author=$(echo "$pr_context" | jq -r '.author // "unknown"')
                pr_state=$(echo "$pr_context" | jq -r '.state // "unknown"')

                jq -n \
                    --arg mode "$mode" \
                    --arg org "$org" \
                    --arg repo "$repo" \
                    --arg branch "$target_branch" \
                    --arg base_branch "$base_branch" \
                    --arg commit "$commit" \
                    --arg working_dir "$working_dir" \
                    --arg files "$files_changed" \
                    --arg added "$lines_added" \
                    --arg removed "$lines_removed" \
                    --arg commits "$commit_count" \
                    --arg pr_number "$pr_number" \
                    --arg pr_title "$pr_title" \
                    --arg pr_url "$pr_url" \
                    --arg pr_author "$pr_author" \
                    --arg pr_state "$pr_state" \
                    '{
                        mode: $mode,
                        repository: "\($org)/\($repo)",
                        branch: $branch,
                        base_branch: $base_branch,
                        commit: $commit,
                        working_directory: $working_dir,
                        comparison: "\($base_branch)..\($branch)",
                        associated_pr: {
                            number: $pr_number,
                            title: $pr_title,
                            url: $pr_url,
                            author: $pr_author,
                            state: $pr_state
                        },
                        stats: {
                            commits: $commits,
                            files_changed: $files,
                            lines_added: $added,
                            lines_removed: $removed
                        }
                    }'
            else
                # No PR information
                jq -n \
                    --arg mode "$mode" \
                    --arg org "$org" \
                    --arg repo "$repo" \
                    --arg branch "$target_branch" \
                    --arg base_branch "$base_branch" \
                    --arg commit "$commit" \
                    --arg working_dir "$working_dir" \
                    --arg files "$files_changed" \
                    --arg added "$lines_added" \
                    --arg removed "$lines_removed" \
                    --arg commits "$commit_count" \
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
                    }'
            fi
            ;;
        "commit")
            local target_commit
            target_commit=$(echo "$parsed_args" | jq -r '.mode_commit // "unknown"')
            jq -n \
                --arg mode "$mode" \
                --arg org "$org" \
                --arg repo "$repo" \
                --arg commit "$target_commit" \
                --arg working_dir "$working_dir" \
                --arg files "$files_changed" \
                --arg added "$lines_added" \
                --arg removed "$lines_removed" \
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
            target_range=$(echo "$parsed_args" | jq -r '.mode_range // "unknown"')

            # Count commits in range
            local commit_count
            commit_count=$(git rev-list --count "${target_range}" 2> /dev/null || echo "unknown")

            jq -n \
                --arg mode "$mode" \
                --arg org "$org" \
                --arg repo "$repo" \
                --arg range "$target_range" \
                --arg working_dir "$working_dir" \
                --arg files "$files_changed" \
                --arg added "$lines_added" \
                --arg removed "$lines_removed" \
                --arg commits "$commit_count" \
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
            area=$(echo "$parsed_args" | jq -r '.mode_area // "all"')
            jq -n \
                --arg mode "$mode" \
                --arg org "$org" \
                --arg repo "$repo" \
                --arg branch "$branch" \
                --arg working_dir "$working_dir" \
                --arg area "$area" \
                --arg files "$files_changed" \
                --arg added "$lines_added" \
                --arg removed "$lines_removed" \
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
        *)
            jq -n \
                --arg mode "$mode" \
                --arg org "$org" \
                --arg repo "$repo" \
                --arg working_dir "$working_dir" \
                --arg files "$files_changed" \
                --arg added "$lines_added" \
                --arg removed "$lines_removed" \
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

# Handle PR review
handle_pr_review() {
    local pr_identifier="$1"

    # Fetch PR data
    local pr_data
    pr_data=$("$SCRIPT_DIR/pr-context.sh" "$pr_identifier")

    local pr_number org repo head_ref
    pr_number=$(echo "$pr_data" | jq -r '.number')
    org=$(echo "$pr_data" | jq -r '.org')
    repo=$(echo "$pr_data" | jq -r '.repo')
    head_ref=$(echo "$pr_data" | jq -r '.head_ref')

    # Determine if we can use the fast path (local git diff)
    # Fast path conditions:
    # 1. We're in a git repository
    # 2. Current repo matches PR's repo
    # 3. Current branch matches PR's head branch
    local use_fast_path=false
    if git rev-parse --git-dir > /dev/null 2>&1; then
        # Source git helpers to get current repo info
        source "$SCRIPT_DIR/helpers/git-helpers.sh"

        # Check if current repo matches
        local current_git_data
        current_git_data=$(get_git_org_repo 2> /dev/null || echo "|")
        local current_org="${current_git_data%|*}"
        local current_repo="${current_git_data#*|}"
        local current_branch
        current_branch=$(git branch --show-current 2> /dev/null || echo "")

        # Normalize org names to lowercase for comparison
        current_org=$(echo "$current_org" | tr '[:upper:]' '[:lower:]')

        if [ "$current_org" = "$org" ] && [ "$current_repo" = "$repo" ] && [ "$current_branch" = "$head_ref" ]; then
            use_fast_path=true
        fi
    fi

    # Get file path info (pass org/repo if not using fast path)
    local file_info
    if [ "$use_fast_path" = true ]; then
        file_info=$("$SCRIPT_DIR/review-file-path.sh" "pr-$pr_number")
    else
        file_info=$("$SCRIPT_DIR/review-file-path.sh" --org "$org" --repo "$repo" "pr-$pr_number")
    fi

    # Extract file metadata from diff
    local file_metadata
    file_metadata=$(echo "$pr_data" | jq -r '.diff' | "$SCRIPT_DIR/pre-review-context.sh")

    # Build summary for PR
    local diff_content pr_title pr_url
    diff_content=$(echo "$pr_data" | jq -r '.diff')
    pr_title=$(echo "$pr_data" | jq -r '.title')
    pr_url=$(echo "$pr_data" | jq -r '.url')

    local files_changed lines_added lines_removed
    files_changed=$(echo "$diff_content" | grep -E '^diff --git' | wc -l | tr -d ' ')
    lines_added=$(echo "$diff_content" | grep -E '^\+' | grep -v -E '^\+\+\+' | wc -l | tr -d ' ')
    lines_removed=$(echo "$diff_content" | grep -E '^-' | grep -v -E '^---' | wc -l | tr -d ' ')

    local summary
    summary=$(jq -n \
        --arg mode "pr" \
        --arg org "$org" \
        --arg repo "$repo" \
        --arg pr_number "$pr_number" \
        --arg pr_title "$pr_title" \
        --arg pr_url "$pr_url" \
        --arg branch "$head_ref" \
        --arg files "$files_changed" \
        --arg added "$lines_added" \
        --arg removed "$lines_removed" \
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
        }')

    # Output JSON for Claude
    debug_time "07-final-output" "start"
    local final_output
    final_output=$(jq -n \
        --argjson pr "$pr_data" \
        --argjson file "$file_info" \
        --argjson meta "$file_metadata" \
        --argjson summary "$summary" \
        '{
            status: "ready",
            mode: "pr",
            pr: $pr,
            file_info: $file,
            file_metadata: $meta,
            summary: $summary,
            next_step: "gather_architectural_context"
        }')
    debug_save_json "07-final-output" "output.json" <<< "$final_output"
    debug_time "07-final-output" "end"
    debug_time "00-orchestrator" "end"
    debug_finalize

    echo "$final_output"
}

# Handle commit review
handle_commit_review() {
    local commit="$1"

    # Get git context
    local git_context
    git_context=$("$SCRIPT_DIR/git-context.sh")

    # Get diff for commit
    local diff_content
    if [ -n "$pattern" ]; then
        diff_content=$("$SCRIPT_DIR/get-review-diff.sh" commit "$commit" "$pattern")
    else
        diff_content=$("$SCRIPT_DIR/get-review-diff.sh" commit "$commit")
    fi

    # Use common helper to build review data
    build_review_data "commit" "$diff_content" "$git_context" "commit-$commit" "" \
        --arg mode_commit "$commit"
}

# Handle branch review
handle_branch_review() {
    local branch="$1"
    local base_branch="$2"
    local associated_pr="${3:-}"

    # Get git context
    local git_context
    git_context=$("$SCRIPT_DIR/git-context.sh")

    # Fetch PR context if available
    local pr_context=""
    if [ -n "$associated_pr" ]; then
        pr_context=$("$SCRIPT_DIR/pr-context.sh" "$associated_pr" 2>/dev/null || echo "")
    fi

    # Get diff for branch
    local diff_content
    if [ -n "$pattern" ]; then
        diff_content=$("$SCRIPT_DIR/get-review-diff.sh" branch "$branch" "$base_branch" "$pattern")
    else
        diff_content=$("$SCRIPT_DIR/get-review-diff.sh" branch "$branch" "$base_branch")
    fi

    # Use common helper to build review data
    if [ -n "$pr_context" ]; then
        build_review_data "branch" "$diff_content" "$git_context" "branch-$branch" "$pr_context" \
            --arg mode_branch "$branch" \
            --arg mode_base_branch "$base_branch" \
            --arg mode_associated_pr "$associated_pr"
    else
        build_review_data "branch" "$diff_content" "$git_context" "branch-$branch" "" \
            --arg mode_branch "$branch" \
            --arg mode_base_branch "$base_branch"
    fi
}

# Handle range review
handle_range_review() {
    local range="$1"

    # Get git context
    local git_context
    git_context=$("$SCRIPT_DIR/git-context.sh")

    # Get diff for range
    local diff_content
    if [ -n "$pattern" ]; then
        diff_content=$("$SCRIPT_DIR/get-review-diff.sh" range "$range" "$pattern")
    else
        diff_content=$("$SCRIPT_DIR/get-review-diff.sh" range "$range")
    fi

    # Use common helper to build review data
    build_review_data "range" "$diff_content" "$git_context" "range-$range" "" \
        --arg mode_range "$range"
}

# Handle local review (uncommitted changes)
handle_local_review() {
    local area="$1" # Optional: security, performance, etc. or empty for all

    # Get git context
    local git_context
    git_context=$("$SCRIPT_DIR/git-context.sh")

    # Get diff for local changes
    local diff_content
    if [ -n "$pattern" ]; then
        diff_content=$("$SCRIPT_DIR/get-review-diff.sh" local "$pattern")
    else
        diff_content=$("$SCRIPT_DIR/get-review-diff.sh" local)
    fi

    # Check if there are actually changes
    if echo "$diff_content" | grep -q "^Error: No changes found"; then
        echo "{\"status\":\"error\",\"message\":\"No changes found (no staged, unstaged, or branch changes)\"}" >&2
        exit 1
    fi

    # Use common helper to build review data
    if [ -n "$area" ]; then
        build_review_data "local" "$diff_content" "$git_context" "" "" \
            --arg mode_area "$area"
    else
        build_review_data "local" "$diff_content" "$git_context" "" ""
    fi
}

main "$@"
