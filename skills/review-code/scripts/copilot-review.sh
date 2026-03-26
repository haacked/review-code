#!/usr/bin/env bash
# copilot-review.sh - Run Copilot CLI code review and return results as JSON
#
# Usage:
#   echo '{"repo_dir": "/path/to/repo", "timeout_seconds": 180}' | copilot-review.sh
#
# Input (stdin): JSON with repo_dir and optional timeout_seconds
# Output (stdout): JSON with available, timed_out, raw_output, duration_ms
#
# Copilot runs its own /review command with file access to the repo.
# Output is raw text for the Claude orchestrator to parse during synthesis.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/copilot-helpers.sh
source "${SCRIPT_DIR}/helpers/copilot-helpers.sh"

main() {
    # Check availability first
    if ! copilot_available; then
        copilot_json_output false false raw_output "" duration_ms 0
        return 0
    fi

    # Parse input JSON from stdin
    local input
    input=$(cat)

    local repo_dir timeout_secs
    repo_dir=$(echo "${input}" | jq -r '.repo_dir // "."')
    timeout_secs=$(echo "${input}" | jq -r '.timeout_seconds // "'"${COPILOT_REVIEW_TIMEOUT}"'"')

    # Validate repo_dir exists
    if [[ ! -d "${repo_dir}" ]]; then
        copilot_json_output true false \
            raw_output "" \
            error "repo_dir does not exist: ${repo_dir}" \
            duration_ms 0
        return 0
    fi

    # Run copilot review with timeout
    local raw_output="" duration_ms=0
    local run_result=0
    copilot_run_with_timeout "${timeout_secs}" raw_output duration_ms \
        -p "/review" \
        --yolo \
        --add-dir "${repo_dir}" \
        --output-format json \
        --silent || run_result=$?

    case "${run_result}" in
        0)
            # Success: parse the JSONL output to extract the review text
            local parsed_output
            parsed_output=$(echo "${raw_output}" | copilot_parse_final_message)
            copilot_json_output true false \
                raw_output "${parsed_output}" \
                duration_ms "${duration_ms}"
            ;;
        1)
            # Timeout
            copilot_json_output true true \
                raw_output "" \
                duration_ms "${duration_ms}"
            ;;
        *)
            # Other error
            copilot_json_output true false \
                raw_output "" \
                error "copilot exited with error" \
                duration_ms "${duration_ms}"
            ;;
    esac
}

main "$@"
