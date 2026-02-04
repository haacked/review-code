#!/usr/bin/env bash
# learn-orchestrator.sh - Orchestrates learn mode workflow
#
# Usage:
#   learn-orchestrator.sh <submode> [arguments]
#
# Submodes:
#   single <pr_number> [--org ORG] [--repo REPO]
#     Analyze outcomes of a specific PR
#
#   batch [--limit N]
#     Find and list unanalyzed PRs with existing reviews
#
#   apply [--threshold N]
#     Synthesize learnings into context file proposals
#
# Description:
#   Handles all learn mode workflow orchestration:
#   - Coordinates the learn-from-pr.sh, learn-batch.sh, and learn-apply.sh scripts
#   - Outputs structured JSON for Claude to process interactively
#
# Output:
#   JSON object with status and data for Claude to handle user interaction

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helpers
source "${SCRIPT_DIR}/helpers/error-helpers.sh"

# Output JSON error
output_error() {
    local message="$1"
    jq -n --arg msg "${message}" '{"status":"error","error":$msg}'
}

# Check if JSON response contains an error field, output and exit if so
# Usage: check_json_error <json_data>
check_json_error() {
    local json_data="$1"
    if echo "${json_data}" | jq -e '.error' > /dev/null 2>&1; then
        local err_msg
        err_msg=$(echo "${json_data}" | jq -r '.error')
        output_error "${err_msg}"
        exit 1
    fi
}

# Handle single PR analysis
handle_single() {
    local pr_number=""
    local org=""
    local repo=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --org)
                org="$2"
                shift 2
                ;;
            --repo)
                repo="$2"
                shift 2
                ;;
            *)
                if [[ -z "${pr_number}" ]]; then
                    pr_number="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${pr_number}" ]]; then
        output_error "PR number required for single mode"
        exit 1
    fi

    # Build arguments for learn-from-pr.sh
    local args=("${pr_number}")
    [[ -n "${org}" ]] && args+=("--org" "${org}")
    [[ -n "${repo}" ]] && args+=("--repo" "${repo}")

    # Run the analysis
    local learn_data
    if ! learn_data=$("${SCRIPT_DIR}/learn-from-pr.sh" "${args[@]}" 2>&1); then
        output_error "Failed to analyze PR #${pr_number}: ${learn_data}"
        exit 1
    fi

    check_json_error "${learn_data}"

    # Extract summary for display
    local summary
    summary=$(echo "${learn_data}" | jq '{
        pr_number: .pr_number,
        org: .org,
        repo: .repo,
        claude_total: .summary.claude_total,
        claude_addressed: .summary.claude_addressed,
        claude_not_addressed: .summary.claude_not_addressed,
        other_total: .summary.other_total,
        other_caught_by_claude: .summary.other_caught_by_claude,
        other_missed_by_claude: .summary.other_missed_by_claude,
        prompts_count: (.prompts_needed | length)
    }')

    # Output structured result
    jq -n \
        --arg status "ready" \
        --argjson summary "${summary}" \
        --argjson learn_data "${learn_data}" \
        '{
            status: $status,
            submode: "single",
            summary: $summary,
            learn_data: $learn_data
        }'
}

# Handle batch mode
handle_batch() {
    local limit=5

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                limit="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Find unanalyzed PRs
    local unanalyzed
    if ! unanalyzed=$("${SCRIPT_DIR}/learn-batch.sh" --limit "${limit}" 2>&1); then
        output_error "Failed to find unanalyzed PRs: ${unanalyzed}"
        exit 1
    fi

    check_json_error "${unanalyzed}"

    local count
    count=$(echo "${unanalyzed}" | jq 'length')

    # Output structured result
    jq -n \
        --arg status "ready" \
        --argjson count "${count}" \
        --argjson prs "${unanalyzed}" \
        '{
            status: $status,
            submode: "batch",
            count: $count,
            prs: $prs
        }'
}

# Handle apply mode
handle_apply() {
    local threshold=3

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold)
                threshold="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Get proposals
    local proposals
    if ! proposals=$("${SCRIPT_DIR}/learn-apply.sh" --threshold "${threshold}" 2>&1); then
        output_error "Failed to generate proposals: ${proposals}"
        exit 1
    fi

    check_json_error "${proposals}"

    local actionable
    actionable=$(echo "${proposals}" | jq '.summary.actionable_proposals')

    # Output structured result
    jq -n \
        --arg status "ready" \
        --argjson actionable "${actionable}" \
        --argjson proposals "${proposals}" \
        '{
            status: $status,
            submode: "apply",
            actionable: $actionable,
            proposals: $proposals
        }'
}

# Main function
main() {
    local submode="${1:-}"

    if [[ -z "${submode}" ]]; then
        output_error "Submode required: single, batch, or apply"
        exit 1
    fi

    shift

    case "${submode}" in
        single)
            handle_single "$@"
            ;;
        batch)
            handle_batch "$@"
            ;;
        apply)
            handle_apply "$@"
            ;;
        *)
            output_error "Unknown submode: ${submode}. Use single, batch, or apply."
            exit 1
            ;;
    esac
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
