#!/usr/bin/env bash
# copilot-meta-review.sh - Use Copilot CLI to validate review findings and do a cursory code scan
#
# Usage:
#   echo '{"findings": [...], "diff": "<diff text>", "timeout_seconds": 120}' | copilot-meta-review.sh
#
# Input (stdin): JSON with findings array (required), diff (optional), and optional timeout_seconds
# Output (stdout): JSON with available, timed_out, validations, missed_issues, duration_ms
#
# Replaces the previous parallel copilot-review.sh approach (which always timed out)
# with a lighter meta-review: validate Claude's findings + cursory scan for obvious misses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/copilot-helpers.sh
source "${SCRIPT_DIR}/helpers/copilot-helpers.sh"

build_meta_review_prompt() {
    local findings_text="$1"
    local diff="$2"

    cat << PROMPT
You are a skeptical senior engineer performing a meta-review. You have two tasks:

## Task 1: Validate Existing Findings

For each finding below, try to DISPROVE it. Your default posture is that the finding is wrong until proven otherwise. Consider:
- Is it based on a misreading of the code?
- Does the code handle this case correctly through a path the reviewer missed?
- Is there a guard, check, middleware, or framework feature that prevents the issue?
- Is the scenario purely theoretical with no realistic trigger?
- Does the proposed fix introduce its own problems?

**Findings:**
${findings_text}
PROMPT

    if [[ -n "${diff}" ]]; then
        cat << PROMPT

## Task 2: Cursory Scan for Missed Issues

Scan the diff for anything glaringly obvious that was NOT covered by the findings above. Focus only on:
- Security vulnerabilities (injection, auth bypass, secrets)
- Crash-causing bugs (null deref, out-of-bounds, unhandled errors)
- Data loss or corruption risks

Do NOT flag style issues, naming, or minor suggestions. Only flag things a senior engineer would consider obviously wrong.

\`\`\`diff
${diff}
\`\`\`
PROMPT
    fi

    cat << 'PROMPT'

## Response Format

Respond with valid JSON only. No markdown fencing, no preamble, no explanation outside the JSON:

{
  "validations": [
    {"finding_id": <number>, "verdict": "CONFIRMED|DISMISSED|ADJUSTED", "reasoning": "<concrete explanation citing code>"}
  ],
  "missed_issues": [
    {"file": "<path>", "line": <number>, "type": "blocking|suggestion", "description": "<what is wrong and why>"}
  ]
}

If all findings are valid and nothing was missed, return empty arrays.
PROMPT
}

format_findings_for_prompt() {
    local findings_json="$1"
    jq -r '.[] | "#\(.id) [\(.type)] \(.file):\(.line) (confidence: \(.confidence)%)\n  Agent: \(.agent)\n  Description: \(.description)\n  Proposed fix: \(.proposed_fix // "none")\n"' <<< "${findings_json}"
}

parse_structured_response() {
    local text="$1"
    local json_text

    # Try full text first so nested pretty-printed JSON is preserved
    if printf '%s' "${text}" | jq -e '.validations and .missed_issues' > /dev/null 2>&1; then
        printf '%s' "${text}"
        return 0
    fi

    # If wrapped in markdown fences, strip them and try again
    json_text=$(printf '%s' "${text}" | sed -n '/^```/,/^```/p' | sed '1d;$d')
    if [[ -n "${json_text}" ]] && printf '%s' "${json_text}" | jq -e '.validations and .missed_issues' > /dev/null 2>&1; then
        printf '%s' "${json_text}"
        return 0
    fi

    return 1
}

parse_freeform_fallback() {
    local text="$1"
    local findings_json="$2"
    local validations="[]"
    local finding_ids
    finding_ids=$(jq -r '.[].id' <<< "${findings_json}")

    for fid in ${finding_ids}; do
        local verdict_line
        # Require non-digit boundary after ID so #1 does not match #10
        verdict_line=$(printf '%s' "${text}" | grep -iE "(#${fid}([^0-9]|$)|finding[[:space:]]+${fid}([^0-9]|$)|^${fid}[.):])" | grep -iwE "CONFIRMED|DISMISSED|ADJUSTED" | head -1)

        if [[ -n "${verdict_line}" ]]; then
            local verdict
            verdict=$(printf '%s' "${verdict_line}" | grep -iowE 'CONFIRMED|DISMISSED|ADJUSTED' | head -1 | tr '[:lower:]' '[:upper:]')
            local reasoning
            reasoning=$(printf '%s' "${verdict_line}" | sed "s/.*${verdict}[[:space:]]*//" | sed 's/^[[:space:]-]*//')

            validations=$(jq --argjson fid "${fid}" --arg verdict "${verdict}" --arg reasoning "${reasoning}" \
                '. + [{"finding_id": $fid, "verdict": $verdict, "reasoning": $reasoning}]' <<< "${validations}")
        fi
    done

    jq -n --argjson validations "${validations}" \
        '{"validations": $validations, "missed_issues": []}'
}

meta_review_json_output() {
    local available="$1"
    local timed_out="$2"
    shift 2

    local jq_args=(
        --argjson available "${available}"
        --argjson timed_out "${timed_out}"
    )
    local has_validations=false has_missed=false

    while [[ $# -ge 2 ]]; do
        local key="$1" value="$2"
        shift 2
        case "${key}" in
            validations)
                jq_args+=(--argjson validations "${value}")
                has_validations=true
                ;;
            missed_issues)
                jq_args+=(--argjson missed_issues "${value}")
                has_missed=true
                ;;
            duration_ms) jq_args+=(--argjson duration_ms "${value}") ;;
            *) jq_args+=(--arg "${key}" "${value}") ;;
        esac
    done

    [[ "${has_validations}" == "false" ]] && jq_args+=(--argjson validations '[]')
    [[ "${has_missed}" == "false" ]] && jq_args+=(--argjson missed_issues '[]')

    jq -n "${jq_args[@]}" '$ARGS.named'
}

main() {
    if ! copilot_available; then
        meta_review_json_output false false duration_ms 0
        return 0
    fi

    # Single jq call to extract all input fields
    local input parsed_fields findings_json diff timeout_secs
    input=$(cat)
    parsed_fields=$(jq -r --arg default_timeout "${COPILOT_META_REVIEW_TIMEOUT}" \
        '[(.findings // []), (.diff // ""), (.timeout_seconds // ($default_timeout | tonumber))] | @json' <<< "${input}")
    findings_json=$(jq -r '.[0]' <<< "${parsed_fields}")
    diff=$(jq -r '.[1]' <<< "${parsed_fields}")
    timeout_secs=$(jq -r '.[2]' <<< "${parsed_fields}")

    local findings_count
    findings_count=$(jq 'length' <<< "${findings_json}")
    if [[ "${findings_count}" -eq 0 ]]; then
        meta_review_json_output true false duration_ms 0
        return 0
    fi

    # Clear diff if it exceeds Copilot's practical limits (byte count, not char count)
    if [[ -n "${diff}" ]]; then
        local diff_bytes
        diff_bytes=$(printf '%s' "${diff}" | LC_ALL=C wc -c | tr -d '[:space:]')
        if [[ "${diff_bytes}" -gt ${COPILOT_MAX_DIFF_BYTES} ]]; then
            diff=""
        fi
    fi

    local findings_text
    findings_text=$(format_findings_for_prompt "${findings_json}")
    local prompt
    prompt=$(build_meta_review_prompt "${findings_text}" "${diff}")

    local raw_output="" duration_ms=0 log_file=""
    local run_result=0
    copilot_run_with_timeout "${timeout_secs}" raw_output duration_ms log_file \
        -p "${prompt}" \
        --output-format json \
        --silent || run_result=$?

    local stderr_tail=""
    [[ "${run_result}" -ne 0 ]] && stderr_tail=$(copilot_read_stderr "${log_file}")

    case "${run_result}" in
        0)
            local parsed_text
            parsed_text=$(copilot_parse_final_message <<< "${raw_output}")

            # Try structured JSON, fall back to freeform verdict extraction
            local result
            if ! result=$(parse_structured_response "${parsed_text}"); then
                result=$(parse_freeform_fallback "${parsed_text}" "${findings_json}")
            fi

            local validations missed_issues
            validations=$(jq '.validations // []' <<< "${result}")
            missed_issues=$(jq '.missed_issues // []' <<< "${result}")

            meta_review_json_output true false \
                validations "${validations}" \
                missed_issues "${missed_issues}" \
                raw_output "${parsed_text}" \
                copilot_log "${log_file}" \
                duration_ms "${duration_ms}"
            ;;
        1)
            meta_review_json_output true true \
                raw_output "" \
                copilot_log "${log_file}" \
                copilot_stderr "${stderr_tail}" \
                duration_ms "${duration_ms}"
            ;;
        *)
            meta_review_json_output true false \
                error "copilot exited with error" \
                raw_output "" \
                copilot_log "${log_file}" \
                copilot_stderr "${stderr_tail}" \
                duration_ms "${duration_ms}"
            ;;
    esac
}

main "$@"
