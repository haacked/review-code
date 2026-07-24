#!/usr/bin/env bash
# codex-meta-review.sh - Use Codex CLI to validate review findings and do a cursory code scan
#
# Usage:
#   echo '{"findings": [...], "diff": "<diff text>", "timeout_seconds": 300}' | codex-meta-review.sh
#
# Input (stdin): JSON with findings array (required), diff (optional), and optional timeout_seconds
# Output (stdout): JSON with available, timed_out, validations, missed_issues, duration_ms
#
# Mirrors copilot-meta-review.sh's contract so the review handler can dispatch to either
# engine interchangeably: validate Claude's findings + cursory scan for obvious misses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/codex-helpers.sh
source "${SCRIPT_DIR}/helpers/codex-helpers.sh"
# shellcheck source=helpers/meta-review-shared.sh
source "${SCRIPT_DIR}/helpers/meta-review-shared.sh"

main() {
    if ! codex_available; then
        meta_review_json_output false false duration_ms 0
        return 0
    fi

    # Single jq call to extract all input fields
    local input parsed_fields findings_json diff timeout_secs
    input=$(cat)
    parsed_fields=$(jq -r --arg default_timeout "${CODEX_META_REVIEW_TIMEOUT}" \
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

    # Clear diff if it exceeds Codex's practical limits (byte count, not char count)
    if [[ -n "${diff}" ]]; then
        local diff_bytes
        diff_bytes=$(printf '%s' "${diff}" | LC_ALL=C wc -c | tr -d '[:space:]')
        if [[ "${diff_bytes}" -gt ${CODEX_MAX_DIFF_BYTES} ]]; then
            diff=""
        fi
    fi

    local findings_text
    findings_text=$(format_findings_for_prompt "${findings_json}")
    local prompt
    prompt=$(build_meta_review_prompt "${findings_text}" "${diff}")

    local raw_output="" duration_ms=0 log_file=""
    local run_result=0
    run_cli_with_timeout codex "${CODEX_LOG_DIR}" codex "${timeout_secs}" raw_output duration_ms log_file \
        exec --json --sandbox read-only "${prompt}" || run_result=$?

    local stderr_tail=""
    [[ "${run_result}" -ne 0 ]] && stderr_tail=$(cli_read_stderr "${log_file}")

    case "${run_result}" in
        0)
            local parsed_text
            parsed_text=$(codex_parse_final_message <<< "${raw_output}")

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
                codex_log "${log_file}" \
                duration_ms "${duration_ms}"
            ;;
        1)
            meta_review_json_output true true \
                raw_output "" \
                codex_log "${log_file}" \
                codex_stderr "${stderr_tail}" \
                duration_ms "${duration_ms}"
            ;;
        *)
            meta_review_json_output true false \
                error "codex exited with error" \
                raw_output "" \
                codex_log "${log_file}" \
                codex_stderr "${stderr_tail}" \
                duration_ms "${duration_ms}"
            ;;
    esac
}

main "$@"
