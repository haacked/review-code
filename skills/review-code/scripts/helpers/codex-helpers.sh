#!/usr/bin/env bash
# Shared helpers for Codex CLI integration
# Provides availability detection and Codex-specific JSONL parsing.
# Timeout execution and log handling live in cli-timeout-helpers.sh, shared
# with every other adversary engine.

_CODEX_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/cli-timeout-helpers.sh
source "${_CODEX_HELPER_DIR}/cli-timeout-helpers.sh"

# Timeout (seconds)
CODEX_META_REVIEW_TIMEOUT="${CODEX_META_REVIEW_TIMEOUT:-300}"

# Max diff size (bytes) to send to Codex. Precautionary: reuses Copilot's
# measured 100KB timeout cutoff as a starting point pending Codex-specific data.
CODEX_MAX_DIFF_BYTES="${CODEX_MAX_DIFF_BYTES:-102400}"

# Directory for Codex stderr logs (persisted for post-mortem debugging)
CODEX_LOG_DIR="${CODEX_LOG_DIR:-${HOME}/.cache/review-code/codex-logs}"

# Check if Codex CLI is installed
# Returns: 0 if available, 1 if not
codex_available() {
    command -v codex > /dev/null 2>&1
}

# Extract the final assistant message text from Codex `exec --json` JSONL output.
# Reads from stdin, writes extracted text to stdout.
# Codex emits one JSON object per line (thread.started, turn.started, item.started/
# completed, turn.completed, ...); the response we want is the text of the last
# `item.completed` event whose `item.type` is `agent_message`.
codex_parse_final_message() {
    local raw_jsonl
    raw_jsonl=$(cat)

    local result=""
    result=$(printf '%s\n' "${raw_jsonl}" | jq -s -r '
		[ .[] |
			select(.type == "item.completed" and .item.type == "agent_message") |
			.item.text
			| select(. != null and . != "")
		] | .[-1] // empty
	' 2> /dev/null)

    # If nothing matched the expected event shape, the output might be plain text
    if [[ -z "${result}" ]]; then
        result="${raw_jsonl}"
    fi

    echo "${result}"
}
