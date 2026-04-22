#!/usr/bin/env bash
# copilot-review.sh - Run Copilot CLI code review on a diff and return results as JSON
#
# NOTE: No longer called from the review flow. Replaced by copilot-meta-review.sh
# which validates Claude's findings instead of running a full independent review.
# Kept for potential standalone use.
#
# Usage:
#   echo '{"diff": "<diff text>", "timeout_seconds": 300}' | copilot-review.sh
#
# Input (stdin): JSON with diff (required) and optional timeout_seconds
# Output (stdout): JSON with available, timed_out, raw_output, duration_ms
#
# Passes the diff directly in the prompt instead of using --add-dir,
# which avoids hitting Copilot's context window limits on large repos.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/copilot-helpers.sh
source "${SCRIPT_DIR}/helpers/copilot-helpers.sh"

build_review_prompt() {
    local diff="$1"

    cat << PROMPT
Review the following code diff. For each issue found, report:
- File path and line number
- Severity (blocking, suggestion, nit)
- Description of the issue
- Suggested fix if applicable

Focus on bugs, security issues, correctness problems, and significant maintainability concerns. Skip trivial style issues.

\`\`\`diff
${diff}
\`\`\`
PROMPT
}

main() {
    # Check availability first
    if ! copilot_available; then
        copilot_json_output false false raw_output "" duration_ms 0
        return 0
    fi

    # Parse input JSON from stdin (single jq call for all fields)
    local input diff timeout_secs
    input=$(cat)
    diff=$(jq -r '.diff // ""' <<< "${input}")
    timeout_secs=$(jq -r '.timeout_seconds // "'"${COPILOT_REVIEW_TIMEOUT}"'"' <<< "${input}")

    # Validate diff is not empty
    if [[ -z "${diff}" ]]; then
        copilot_json_output true false \
            raw_output "" \
            error "diff is empty" \
            duration_ms 0
        return 0
    fi

    # Skip if diff exceeds Copilot's practical limits
    local diff_bytes
    diff_bytes=$(printf '%s' "${diff}" | LC_ALL=C wc -c | tr -d '[:space:]')
    if [[ "${diff_bytes}" -gt ${COPILOT_MAX_DIFF_BYTES} ]]; then
        copilot_json_output true false \
            raw_output "" \
            error "diff too large for copilot (${diff_bytes} bytes, max ${COPILOT_MAX_DIFF_BYTES})" \
            duration_ms 0
        return 0
    fi

    # Build the review prompt with the diff embedded
    local prompt
    prompt=$(build_review_prompt "${diff}")

    # Run copilot with timeout, passing diff in the prompt (no --add-dir)
    local raw_output="" duration_ms=0 log_file=""
    local run_result=0
    copilot_run_with_timeout "${timeout_secs}" raw_output duration_ms log_file \
        -p "${prompt}" \
        --output-format json \
        --silent || run_result=$?

    # Read stderr on failure for inclusion in JSON output
    local stderr_tail=""
    [[ "${run_result}" -ne 0 ]] && stderr_tail=$(copilot_read_stderr "${log_file}")

    case "${run_result}" in
        0)
            # Success: parse the JSONL output to extract the review text
            local parsed_output
            parsed_output=$(copilot_parse_final_message <<< "${raw_output}")
            copilot_json_output true false \
                raw_output "${parsed_output}" \
                copilot_log "${log_file}" \
                duration_ms "${duration_ms}"
            ;;
        1)
            # Timeout
            copilot_json_output true true \
                raw_output "" \
                copilot_log "${log_file}" \
                copilot_stderr "${stderr_tail}" \
                duration_ms "${duration_ms}"
            ;;
        *)
            # Other error
            copilot_json_output true false \
                raw_output "" \
                error "copilot exited with error" \
                copilot_log "${log_file}" \
                copilot_stderr "${stderr_tail}" \
                duration_ms "${duration_ms}"
            ;;
    esac
}

main "$@"
