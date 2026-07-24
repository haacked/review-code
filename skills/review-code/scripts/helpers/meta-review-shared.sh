#!/usr/bin/env bash
# Shared, engine-agnostic logic for the *-meta-review.sh scripts (copilot, codex, ...).
# Builds the meta-review prompt, formats findings, and parses the model's
# response. None of this touches a specific CLI; each *-meta-review.sh main()
# supplies the engine-specific availability check, invocation, and response
# extraction, then calls into these functions with the resulting text.

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
