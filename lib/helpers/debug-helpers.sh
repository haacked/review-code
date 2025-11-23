#!/usr/bin/env bash
# Debug helpers for review-code
# Provides utilities for capturing intermediate artifacts and command logs when DEBUG mode is enabled

# Initialize DEBUG_SESSION_DIR to empty to prevent unbound variable errors with set -u
export DEBUG_SESSION_DIR="${DEBUG_SESSION_DIR:-}"

# Check if debug mode is enabled
# Returns: 0 if enabled, 1 if disabled
is_debug_enabled() {
    [[ "${REVIEW_CODE_DEBUG:-0}" = "1" ]]
}

# Initialize debug session directory
# Creates a timestamped directory for storing debug artifacts
# Usage: debug_init "identifier" "org" "repo" "mode"
# Example: debug_init "pr-123" "posthog" "posthog" "pr"
debug_init() {
    is_debug_enabled || return 0

    local identifier="${1:-unknown}"
    local org="${2:-unknown}"
    local repo="${3:-unknown}"
    local mode="${4:-unknown}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)

    # Use cache directory for debug artifacts
    local debug_base="${REVIEW_CODE_DEBUG_PATH:-${HOME}/.cache/review-code/debug}"
    export DEBUG_SESSION_DIR="${debug_base}/${org}-${repo}-${identifier}-${timestamp}"

    mkdir -p "${DEBUG_SESSION_DIR}"
    chmod 700 "${DEBUG_SESSION_DIR}" # Restrict to owner only for security

    # Create session metadata
    cat > "${DEBUG_SESSION_DIR}/session.json" << EOF
{
  "identifier": "${identifier}",
  "org": "${org}",
  "repo": "${repo}",
  "mode": "${mode}",
  "timestamp": "${timestamp}",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "debug_dir": "${DEBUG_SESSION_DIR}"
}
EOF

    echo "Debug session: ${DEBUG_SESSION_DIR}" >&2
}

# Save debug artifact from string
# Usage: debug_save "stage-name" "filename.txt" "$content"
# Example: debug_save "01-diff-generation" "raw-diff.txt" "$diff"
debug_save() {
    is_debug_enabled || return 0
    [[ -n "${DEBUG_SESSION_DIR}" ]] || return 0 # Skip if debug_init not called yet

    local stage="$1"
    local filename="$2"
    local content="$3"

    local stage_dir="${DEBUG_SESSION_DIR}/${stage}"
    mkdir -p "${stage_dir}"
    echo "${content}" > "${stage_dir}/${filename}"
}

# Save debug artifact from file
# Usage: debug_save_file "stage-name" "filename.txt" /path/to/source
# Example: debug_save_file "01-diff-generation" "raw-diff.txt" /tmp/diff.txt
debug_save_file() {
    is_debug_enabled || return 0
    [[ -n "${DEBUG_SESSION_DIR}" ]] || return 0 # Skip if debug_init not called yet

    local stage="$1"
    local filename="$2"
    local source_file="$3"

    local stage_dir="${DEBUG_SESSION_DIR}/${stage}"
    mkdir -p "${stage_dir}"
    cp "${source_file}" "${stage_dir}/${filename}"
}

# Save JSON artifact with pretty formatting
# Usage: echo "$json" | debug_save_json "stage-name" "output.json"
# Example: echo '{"foo":"bar"}' | debug_save_json "02-metadata" "result.json"
debug_save_json() {
    is_debug_enabled || return 0
    [[ -n "${DEBUG_SESSION_DIR}" ]] || return 0 # Skip if debug_init not called yet

    local stage="$1"
    local filename="$2"

    local stage_dir="${DEBUG_SESSION_DIR}/${stage}"
    mkdir -p "${stage_dir}"

    # Try to format as JSON, but save raw content if jq fails
    # Use mktemp with template in secure directory to prevent race conditions
    local temp_file
    temp_file=$(mktemp "${stage_dir}/.tmp.XXXXXXXX")
    cat > "${temp_file}"
    jq '.' "${temp_file}" > "${stage_dir}/${filename}" 2> /dev/null || cp "${temp_file}" "${stage_dir}/${filename}"
    rm -f "${temp_file}"
}

# Log command execution with full output capture
# Executes command and saves: command string, stdout, stderr, exit code
# Usage: debug_log_command "stage-name" "description" command args...
# Example: debug_log_command "01-diff" "Generate diff" git diff main...HEAD
debug_log_command() {
    is_debug_enabled || return 0
    [[ -n "${DEBUG_SESSION_DIR}" ]] || return 0 # Skip if debug_init not called yet

    local stage="$1"
    local description="$2"
    shift 2

    local stage_dir="${DEBUG_SESSION_DIR}/${stage}"
    mkdir -p "${stage_dir}"

    local cmd_file="${stage_dir}/commands.log"
    local stdout_file="${stage_dir}/stdout.log"
    local stderr_file="${stage_dir}/stderr.log"

    # Log the command
    {
        echo "=== ${description} ==="
        echo "Command: $*"
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
    } >> "${cmd_file}"

    # Execute and capture output
    local exit_code=0
    "$@" >> "${stdout_file}" 2>> "${stderr_file}" || exit_code=$?

    # Log exit code
    echo "Exit code: ${exit_code}" >> "${cmd_file}"
    echo "" >> "${cmd_file}"

    return "${exit_code}"
}

# Record timing event for performance analysis
# Usage: debug_time "stage-name" "event-type"
# Example: debug_time "01-diff-generation" "start"
#          debug_time "01-diff-generation" "end"
debug_time() {
    is_debug_enabled || return 0
    [[ -n "${DEBUG_SESSION_DIR}" ]] || return 0 # Skip if debug_init not called yet

    local stage="$1"
    local event="$2"

    local timing_file="${DEBUG_SESSION_DIR}/timing.ndjson"
    local timestamp
    timestamp=$(date +%s.%N)

    jq -n \
        --arg stage "${stage}" \
        --arg event "${event}" \
        --arg timestamp "${timestamp}" \
        '{stage: $stage, event: $event, timestamp: ($timestamp | tonumber)}' \
        >> "${timing_file}"
}

# Append to trace log for detailed execution flow
# Usage: debug_trace "stage-name" "message"
# Example: debug_trace "02-metadata" "Detected Python file: src/main.py"
debug_trace() {
    is_debug_enabled || return 0
    [[ -n "${DEBUG_SESSION_DIR}" ]] || return 0 # Skip if debug_init not called yet

    local stage="$1"
    local message="$2"

    local stage_dir="${DEBUG_SESSION_DIR}/${stage}"
    mkdir -p "${stage_dir}"

    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${message}" >> "${stage_dir}/trace.log"
}

# Save statistics as JSON
# Usage: debug_stats "stage-name" key1 value1 key2 value2 ...
# Example: debug_stats "01-diff" lines_before 1000 lines_after 200
debug_stats() {
    is_debug_enabled || return 0
    [[ -n "${DEBUG_SESSION_DIR}" ]] || return 0 # Skip if debug_init not called yet

    local stage="$1"
    shift

    local stage_dir="${DEBUG_SESSION_DIR}/${stage}"
    mkdir -p "${stage_dir}"

    # Build jq arguments from key-value pairs
    local jq_args=()
    while [[ $# -ge 2 ]]; do
        jq_args+=(--arg "$1" "$2")
        shift 2
    done

    # Create stats JSON
    jq -n "${jq_args[@]}" '$ARGS.named' > "${stage_dir}/stats.json"
}

# Finalize debug session with summary
# Generates human-readable summary of the debug session
# Usage: debug_finalize
debug_finalize() {
    is_debug_enabled || return 0
    [[ -n "${DEBUG_SESSION_DIR}" ]] || return 0 # Skip if debug_init not called yet

    local summary_file="${DEBUG_SESSION_DIR}/README.md"

    {
        echo "Review Code Debug Summary"
        echo "========================="
        echo ""

        # Session info
        if [[ -f "${DEBUG_SESSION_DIR}/session.json" ]]; then
            echo "Session Information:"
            jq -r '"  Mode: \(.mode)\n  Identifier: \(.identifier)\n  Repository: \(.org)/\(.repo)\n  Started: \(.started_at)\n  Debug Directory: \(.debug_dir)"' \
                "${DEBUG_SESSION_DIR}/session.json"
            echo ""
        fi

        # Timing summary
        if [[ -f "${DEBUG_SESSION_DIR}/timing.ndjson" ]]; then
            echo "Timing Summary:"
            echo "---------------"

            # Calculate stage durations
            jq -r 'select(.event == "start") | .stage' "${DEBUG_SESSION_DIR}/timing.ndjson" | while read -r stage; do
                local start_time
                local end_time
                start_time=$(jq -r "select(.stage == \"${stage}\" and .event == \"start\") | .timestamp" "${DEBUG_SESSION_DIR}/timing.ndjson" | head -1)
                end_time=$(jq -r "select(.stage == \"${stage}\" and .event == \"end\") | .timestamp" "${DEBUG_SESSION_DIR}/timing.ndjson" | head -1)

                if [[ -n "${start_time}" ]] && [[ -n "${end_time}" ]]; then
                    local duration
                    duration=$(echo "${end_time} - ${start_time}" | bc)
                    printf "  %-30s: %.3fs\n" "${stage}" "${duration}"
                fi
            done
            echo ""
        fi

        # Token savings (if available)
        if [[ -f "${DEBUG_SESSION_DIR}/02-diff-filter/stats.json" ]]; then
            echo "Token Savings:"
            echo "--------------"
            local raw_tokens filtered_tokens tokens_saved
            raw_tokens=$(jq -r '.raw_tokens // "0"' "${DEBUG_SESSION_DIR}/02-diff-filter/stats.json")
            filtered_tokens=$(jq -r '.filtered_tokens // "0"' "${DEBUG_SESSION_DIR}/02-diff-filter/stats.json")
            tokens_saved=$(jq -r '.tokens_saved // "0"' "${DEBUG_SESSION_DIR}/02-diff-filter/stats.json")

            if [[ "${raw_tokens}" != "0" ]]; then
                local savings_pct
                savings_pct=$((tokens_saved * 100 / raw_tokens))
                echo "  Raw diff tokens: ~${raw_tokens}"
                echo "  Filtered diff tokens: ~${filtered_tokens}"
                echo "  Tokens saved: ~${tokens_saved} (${savings_pct}%)"
            fi
            echo ""
        fi

        # List all stages with artifacts
        echo "Debug Artifacts by Stage:"
        echo "-------------------------"
        find "${DEBUG_SESSION_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | while read -r stage_dir; do
            local stage_name
            stage_name=$(basename "${stage_dir}")
            local file_count
            file_count=$(find "${stage_dir}" -type f | wc -l | tr -d ' ')
            echo "  ${stage_name} (${file_count} files)"
        done
        echo ""

        echo "Full debug session saved to:"
        echo "  ${DEBUG_SESSION_DIR}"
        echo ""
        echo "To explore artifacts:"
        echo "  ls -la ${DEBUG_SESSION_DIR}/"
        echo ""
        echo "To view specific stage:"
        echo "  ls -la ${DEBUG_SESSION_DIR}/<stage-name>/"

    } > "${summary_file}"

    # Print summary location to stderr
    echo "Debug README: ${summary_file}" >&2
}
