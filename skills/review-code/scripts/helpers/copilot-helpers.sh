#!/usr/bin/env bash
# Shared helpers for Copilot CLI integration
# Provides availability detection, timeout execution, and JSONL parsing

# Timeouts (seconds)
COPILOT_REVIEW_TIMEOUT="${COPILOT_REVIEW_TIMEOUT:-180}"
COPILOT_VALIDATE_TIMEOUT="${COPILOT_VALIDATE_TIMEOUT:-90}"

# Check if Copilot CLI is installed
# Returns: 0 if available, 1 if not
copilot_available() {
    command -v copilot > /dev/null 2>&1
}

# Get current time in milliseconds
current_time_ms() {
    if command -v gdate > /dev/null 2>&1; then
        echo $(($(gdate +%s%N) / 1000000))
    elif command -v python3 > /dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time() * 1000))'
    else
        echo $(($(date +%s) * 1000))
    fi
}

# Run copilot with a timeout, capturing output and timing
# Usage: copilot_run_with_timeout <timeout_seconds> <output_var> <duration_var> <copilot_args...>
# Sets the named variables via nameref. Returns 0 on success, 1 on timeout, 2 on error.
copilot_run_with_timeout() {
    local timeout_secs="$1"
    local -n _output_ref="$2"
    local -n _duration_ref="$3"
    shift 3

    local start_ms
    start_ms=$(current_time_ms)

    local tmpfile
    tmpfile=$(mktemp)
    trap 'rm -f "${tmpfile}"' RETURN

    local exit_code=0
    if command -v gtimeout > /dev/null 2>&1; then
        gtimeout "${timeout_secs}" copilot "$@" > "${tmpfile}" 2> /dev/null || exit_code=$?
    elif command -v timeout > /dev/null 2>&1; then
        timeout "${timeout_secs}" copilot "$@" > "${tmpfile}" 2> /dev/null || exit_code=$?
    else
        # No timeout command available, run directly
        copilot "$@" > "${tmpfile}" 2> /dev/null || exit_code=$?
    fi

    local end_ms
    end_ms=$(current_time_ms)
    _duration_ref=$((end_ms - start_ms))

    _output_ref=$(cat "${tmpfile}")

    # exit code 124 = timeout (GNU coreutils), 137 = killed
    if [[ "${exit_code}" -eq 124 ]] || [[ "${exit_code}" -eq 137 ]]; then
        return 1
    elif [[ "${exit_code}" -ne 0 ]]; then
        return 2
    fi
    return 0
}

# Extract the final assistant message text from Copilot JSONL output
# Reads from stdin, writes extracted text to stdout
# Copilot JSONL contains many event types; we want the content from assistant messages
copilot_parse_final_message() {
    local raw_jsonl
    raw_jsonl=$(cat)

    # Try to extract content from the last assistant message event
    # Copilot JSONL format has events with "type" fields; the final assistant
    # response content is what we want. Try several known patterns.
    local result=""

    # Extract content from the last matching JSON object, trying structured types first,
    # then falling back to any object with a "content" field
    result=$(echo "${raw_jsonl}" | jq -r '
		if (.type == "result" or .type == "assistant.message" or .type == "message") then
			(.data.content // .content // .message // .text // empty)
		elif .content != null then
			.content
		else
			empty
		end
	' 2> /dev/null | tail -1)

    # Pattern 3: If still nothing, the output might be plain text (not JSONL)
    if [[ -z "${result}" ]]; then
        result="${raw_jsonl}"
    fi

    echo "${result}"
}

# Build a JSON output object for copilot script responses
# Usage: copilot_json_output available timed_out [key value...]
# Example: copilot_json_output true false raw_output "review text" duration_ms 1234
copilot_json_output() {
    local available="$1"
    local timed_out="$2"
    shift 2

    local jq_args=(
        --argjson available "${available}"
        --argjson timed_out "${timed_out}"
    )

    while [[ $# -ge 2 ]]; do
        local key="$1"
        local value="$2"
        shift 2
        jq_args+=(--arg "${key}" "${value}")
    done

    # All variadic pairs are strings; convert _ms fields to numbers in jq
    jq -n "${jq_args[@]}" '$ARGS.named | with_entries(if .key | endswith("_ms") then .value |= tonumber else . end)'
}
