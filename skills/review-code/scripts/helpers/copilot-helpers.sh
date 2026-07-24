#!/usr/bin/env bash
# Shared helpers for Copilot CLI integration
# Provides availability detection and Copilot-specific JSONL parsing.
# Timeout execution and log handling live in cli-timeout-helpers.sh, shared
# with every other adversary engine.

_COPILOT_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/cli-timeout-helpers.sh
source "${_COPILOT_HELPER_DIR}/cli-timeout-helpers.sh"

# Timeout (seconds)
COPILOT_META_REVIEW_TIMEOUT="${COPILOT_META_REVIEW_TIMEOUT:-300}"

# Max diff size (bytes) to send to Copilot. Larger diffs cause timeouts
# (176KB timed out at 180s). 100KB gives headroom for prompt wrapping.
COPILOT_MAX_DIFF_BYTES="${COPILOT_MAX_DIFF_BYTES:-102400}"

# Directory for Copilot stderr logs (persisted for post-mortem debugging)
COPILOT_LOG_DIR="${COPILOT_LOG_DIR:-${HOME}/.cache/review-code/copilot-logs}"

# Check if Copilot CLI is installed
# Returns: 0 if available, 1 if not
copilot_available() {
    command -v copilot > /dev/null 2>&1
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
    result=$(printf '%s\n' "${raw_jsonl}" | jq -s -r '
		[ .[] |
			if (.type == "result" or .type == "assistant.message" or .type == "message") then
				(.data.content // .content // .message // .text // empty)
			elif .content != null then
				.content
			else
				empty
			end
			| select(. != null and . != "")
		] | .[-1] // empty
	' 2> /dev/null)

    # Pattern 3: If still nothing, the output might be plain text (not JSONL)
    if [[ -z "${result}" ]]; then
        result="${raw_jsonl}"
    fi

    echo "${result}"
}
