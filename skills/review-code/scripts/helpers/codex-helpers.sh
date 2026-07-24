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

# Run the Codex CLI for a meta-review. Matches the invoke_fn contract
# documented on meta-review-shared.sh's run_meta_review: forwards the
# output/duration/log-file variable names through to run_cli_with_timeout,
# which binds them in the caller's scope via nameref.
# Usage: codex_invoke <prompt> <timeout_secs> <log_dir> <log_prefix> <output_var> <duration_var> <log_file_var>
codex_invoke() {
    local prompt="$1" timeout_secs="$2" log_dir="$3" log_prefix="$4"
    local output_var="$5" duration_var="$6" log_file_var="$7"
    run_cli_with_timeout codex "${log_dir}" "${log_prefix}" "${timeout_secs}" \
        "${output_var}" "${duration_var}" "${log_file_var}" \
        exec --json --sandbox read-only "${prompt}"
}
