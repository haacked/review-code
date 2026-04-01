#!/usr/bin/env bash
# copilot-validate.sh - Use Copilot CLI to adversarially validate a blocking finding
#
# Usage:
#   echo '{"finding_description": "...", "file": "src/auth.ts", "line": 42,
#          "proposed_fix": "...", "diff_context": "<relevant diff snippet>",
#          "timeout_seconds": 90}' \
#     | copilot-validate.sh
#
# Input (stdin): JSON with finding details and diff context
# Output (stdout): JSON with available, verdict (CONFIRMED|DISMISSED|INCONCLUSIVE), reasoning, duration_ms

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/copilot-helpers.sh
source "${SCRIPT_DIR}/helpers/copilot-helpers.sh"

build_validation_prompt() {
    local finding_description="$1"
    local file="$2"
    local line="$3"
    local proposed_fix="$4"
    local diff_context="$5"

    cat << PROMPT
You are a skeptical senior engineer. A code reviewer flagged this blocking issue:

**Finding:** ${finding_description}
**File:** ${file}:${line}
**Proposed fix:** ${proposed_fix}

Here is the relevant code from the diff:

\`\`\`diff
${diff_context}
\`\`\`

Try to DISPROVE this finding. Your default posture is that the finding is wrong until proven otherwise. Consider:
- Is the finding based on a misreading of the code?
- Does the code handle this case correctly through a path the reviewer missed?
- Is there a guard, check, middleware, or framework feature that prevents the issue?
- Is the scenario purely theoretical with no realistic trigger?
- Does the proposed fix introduce its own problems?

Respond with exactly CONFIRMED or DISMISSED on the FIRST LINE, followed by your reasoning.
Be concrete: cite file paths, line numbers, and code.
PROMPT
}

parse_verdict() {
    local text="$1"

    # Extract the first non-empty line, strip markdown formatting and whitespace
    local first_line
    first_line=$(echo "${text}" | sed '/^[[:space:]]*$/d' | head -1 | tr -d '[:space:]*`#')

    case "${first_line}" in
        CONFIRMED* | confirmed*)
            echo "CONFIRMED"
            ;;
        DISMISSED* | dismissed*)
            echo "DISMISSED"
            ;;
        *)
            echo "INCONCLUSIVE"
            ;;
    esac
}

extract_reasoning() {
    local text="$1"

    # Skip leading blank lines and the verdict line, preserve paragraph structure
    echo "${text}" | awk '/^[[:space:]]*$/ && !v {next} !v {v=1; next} 1'
}

validate_json_output() {
    local available="$1"
    local verdict="$2"
    local reasoning="$3"
    local duration_ms="$4"

    jq -n \
        --argjson available "${available}" \
        --arg verdict "${verdict}" \
        --arg reasoning "${reasoning}" \
        --argjson duration_ms "${duration_ms}" \
        '$ARGS.named'
}

main() {
    # Check availability first
    if ! copilot_available; then
        validate_json_output false "INCONCLUSIVE" "copilot not installed" 0
        return 0
    fi

    # Parse input JSON from stdin
    local input
    input=$(cat)

    local finding_description file line proposed_fix diff_context timeout_secs
    finding_description=$(jq -r '.finding_description // ""' <<< "${input}")
    file=$(jq -r '.file // ""' <<< "${input}")
    line=$(jq -r '.line // 0' <<< "${input}")
    proposed_fix=$(jq -r '.proposed_fix // "none provided"' <<< "${input}")
    diff_context=$(jq -r '.diff_context // ""' <<< "${input}")
    timeout_secs=$(jq -r '.timeout_seconds // "'"${COPILOT_VALIDATE_TIMEOUT}"'"' <<< "${input}")

    # Return INCONCLUSIVE if no diff context to validate against
    if [[ -z "${diff_context}" ]]; then
        validate_json_output true "INCONCLUSIVE" "no diff context provided" 0
        return 0
    fi

    # Build the validation prompt
    local prompt
    prompt=$(build_validation_prompt "${finding_description}" "${file}" "${line}" "${proposed_fix}" "${diff_context}")

    # Run copilot with timeout, passing diff context in the prompt (no --add-dir)
    local raw_output="" duration_ms=0 log_file=""
    local run_result=0
    copilot_run_with_timeout "${timeout_secs}" raw_output duration_ms log_file \
        -p "${prompt}" \
        --output-format json \
        --silent || run_result=$?

    # Read stderr on failure for inclusion in output
    local stderr_tail=""
    [[ "${run_result}" -ne 0 ]] && stderr_tail=$(copilot_read_stderr "${log_file}")

    case "${run_result}" in
        0)
            # Success: parse the output
            local parsed_text
            parsed_text=$(copilot_parse_final_message <<< "${raw_output}")

            local verdict reasoning
            verdict=$(parse_verdict "${parsed_text}")
            reasoning=$(extract_reasoning "${parsed_text}")

            validate_json_output true "${verdict}" "${reasoning}" "${duration_ms}"
            ;;
        1)
            # Timeout
            validate_json_output true "INCONCLUSIVE" "copilot timed out after ${timeout_secs}s (log: ${log_file})${stderr_tail:+ stderr: ${stderr_tail}}" "${duration_ms}"
            ;;
        *)
            # Other error
            validate_json_output true "INCONCLUSIVE" "copilot exited with error (log: ${log_file})${stderr_tail:+ stderr: ${stderr_tail}}" "${duration_ms}"
            ;;
    esac
}

main "$@"
