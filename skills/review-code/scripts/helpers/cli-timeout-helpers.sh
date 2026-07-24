#!/usr/bin/env bash
# Generic helpers for running an external CLI under a timeout with logging.
# Shared by every adversary engine's helpers file (copilot-helpers.sh,
# codex-helpers.sh, ...) so the engine-specific files only need to supply
# their own availability check and response-parsing logic.

# Guard against being sourced more than once per process. Every engine's
# helpers file sources this, so this scales with the number of engines
# installed (review-orchestrator.sh sources every engine's helpers up front).
[[ -n "${_CLI_TIMEOUT_HELPERS_SOURCED:-}" ]] && return
_CLI_TIMEOUT_HELPERS_SOURCED=1

_CLI_TIMEOUT_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/date-helpers.sh
source "${_CLI_TIMEOUT_HELPER_DIR}/date-helpers.sh"

# Clean up log files older than 7 days
# Usage: cli_cleanup_old_logs <log_dir> <name_glob>
cli_cleanup_old_logs() {
    local log_dir="$1"
    local name_glob="$2"
    [[ -d "${log_dir}" ]] || return 0
    # Safety: skip cleanup for root or shallow directories (require 3+ path segments)
    [[ "${log_dir%/}" == */*/* ]] || return 0
    find "${log_dir}" -maxdepth 1 -type f -name "${name_glob}" -mtime +7 -delete 2> /dev/null || true
}

# Run a CLI binary with a timeout, capturing output, timing, and stderr to a log file.
# Usage: run_cli_with_timeout <binary> <log_dir> <log_prefix> <timeout_seconds> <output_var> <duration_var> <log_file_var> <cli_args...>
# Sets the named variables via nameref. Returns 0 on success, 1 on timeout, 2 on error.
run_cli_with_timeout() {
    local binary="$1"
    local log_dir="$2"
    local log_prefix="$3"
    local timeout_secs="$4"
    local -n _output_ref="$5"
    local -n _duration_ref="$6"
    local -n _log_file_ref="$7"
    shift 7

    # Set up log directory and file
    mkdir -p "${log_dir}"
    cli_cleanup_old_logs "${log_dir}" "${log_prefix}-*.log"
    local log_timestamp
    log_timestamp=$(date -u +%Y%m%d-%H%M%SZ)
    _log_file_ref="${log_dir}/${log_prefix}-${log_timestamp}-$$.log"

    # Write log header
    {
        echo "=== ${binary} invocation ==="
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Timeout: ${timeout_secs}s"
        echo "Args: [${#} arguments, prompt omitted]"
        echo "=== stderr ==="
    } > "${_log_file_ref}"

    local start_ms
    start_ms=$(current_time_ms)

    local tmpfile
    tmpfile=$(mktemp)

    local exit_code=0
    if command -v gtimeout > /dev/null 2>&1; then
        gtimeout "${timeout_secs}" "${binary}" "$@" > "${tmpfile}" 2>> "${_log_file_ref}" || exit_code=$?
    elif command -v timeout > /dev/null 2>&1; then
        timeout "${timeout_secs}" "${binary}" "$@" > "${tmpfile}" 2>> "${_log_file_ref}" || exit_code=$?
    else
        # No timeout command available, run directly
        "${binary}" "$@" > "${tmpfile}" 2>> "${_log_file_ref}" || exit_code=$?
    fi

    local end_ms
    end_ms=$(current_time_ms)
    _duration_ref=$((end_ms - start_ms))

    # Append exit code and duration to log
    {
        echo "=== result ==="
        echo "Exit code: ${exit_code}"
        echo "Duration: ${_duration_ref}ms"
    } >> "${_log_file_ref}"

    _output_ref=$(cat "${tmpfile}")
    rm -f "${tmpfile}"

    # exit code 124 = timeout (GNU coreutils), 137 = killed
    if [[ "${exit_code}" -eq 124 ]] || [[ "${exit_code}" -eq 137 ]]; then
        return 1
    elif [[ "${exit_code}" -ne 0 ]]; then
        return 2
    fi
    return 0
}

# Read the last N lines of stderr from a CLI invocation log file (skipping the header)
# Usage: cli_read_stderr <log_file> [max_lines]
cli_read_stderr() {
    local log_file="$1"
    local max_lines="${2:-20}"
    [[ -f "${log_file}" ]] || return 0
    # Extract lines between "=== stderr ===" and "=== result ===" headers
    sed -n '/^=== stderr ===/,/^=== result ===/p' "${log_file}" | sed '1d;$d' | tail -n "${max_lines}"
}
