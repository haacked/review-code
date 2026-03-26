#!/usr/bin/env bash
# copilot-validate.sh - Use Copilot CLI to adversarially validate a blocking finding
#
# Usage:
#   echo '{"finding_description": "...", "file": "src/auth.ts", "line": 42,
#          "proposed_fix": "...", "repo_dir": "/path/to/repo", "timeout_seconds": 90}' \
#     | copilot-validate.sh
#
# Input (stdin): JSON with finding details and repo access info
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

    cat << PROMPT
You are a skeptical senior engineer. A code reviewer flagged this blocking issue:

**Finding:** ${finding_description}
**File:** ${file}:${line}
**Proposed fix:** ${proposed_fix}

Read the file at ${file} (around line ${line}). Try to DISPROVE this finding.
Look for guards, upstream checks, framework features, or misreadings that make it wrong.

Your default posture is that the finding is wrong until proven otherwise. Consider:
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
    first_line=$(echo "${text}" | sed '/^[[:space:]]*$/d' | head -1 | tr -d '[:space:]*\`#')

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

main() {
    # Check availability first
    if ! copilot_available; then
        jq -n '{available: false, verdict: "INCONCLUSIVE", reasoning: "copilot not installed", duration_ms: 0}'
        return 0
    fi

    # Parse input JSON from stdin
    local input
    input=$(cat)

    local finding_description file line proposed_fix repo_dir timeout_secs
    finding_description=$(echo "${input}" | jq -r '.finding_description // ""')
    file=$(echo "${input}" | jq -r '.file // ""')
    line=$(echo "${input}" | jq -r '.line // 0')
    proposed_fix=$(echo "${input}" | jq -r '.proposed_fix // "none provided"')
    repo_dir=$(echo "${input}" | jq -r '.repo_dir // "."')
    timeout_secs=$(echo "${input}" | jq -r '.timeout_seconds // "'"${COPILOT_VALIDATE_TIMEOUT}"'"')

    # Build the validation prompt
    local prompt
    prompt=$(build_validation_prompt "${finding_description}" "${file}" "${line}" "${proposed_fix}")

    # Run copilot with timeout
    local raw_output="" duration_ms=0
    local run_result=0
    copilot_run_with_timeout "${timeout_secs}" raw_output duration_ms \
        -p "${prompt}" \
        --yolo \
        --add-dir "${repo_dir}" \
        --output-format json \
        --silent || run_result=$?

    case "${run_result}" in
        0)
            # Success: parse the output
            local parsed_text
            parsed_text=$(echo "${raw_output}" | copilot_parse_final_message)

            local verdict reasoning
            verdict=$(parse_verdict "${parsed_text}")
            reasoning=$(extract_reasoning "${parsed_text}")

            jq -n \
                --argjson available true \
                --arg verdict "${verdict}" \
                --arg reasoning "${reasoning}" \
                --argjson duration_ms "${duration_ms}" \
                '$ARGS.named'
            ;;
        1)
            # Timeout
            jq -n \
                --argjson available true \
                --arg verdict "INCONCLUSIVE" \
                --arg reasoning "copilot timed out after ${timeout_secs}s" \
                --argjson duration_ms "${duration_ms}" \
                '$ARGS.named'
            ;;
        *)
            # Other error
            jq -n \
                --argjson available true \
                --arg verdict "INCONCLUSIVE" \
                --arg reasoning "copilot exited with error" \
                --argjson duration_ms "${duration_ms}" \
                '$ARGS.named'
            ;;
    esac
}

main "$@"
