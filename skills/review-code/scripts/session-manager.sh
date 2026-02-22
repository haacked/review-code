#!/usr/bin/env bash
# shellcheck disable=SC2310  # Functions in conditionals intentionally check return values
# shellcheck disable=SC2312  # Command substitutions for directory resolution are non-critical
set -euo pipefail

# Session Manager - Generic session state management for Claude Code slash commands
#
# Provides persistent state across multiple Bash tool invocations by storing
# session data in temporary files. Solves the variable scoping problem where
# bash variables don't persist across separate tool calls.
#
# Usage:
#   source session-manager.sh
#   session_init <command-name> <initial-data>
#   session_get <session-id> <field>
#   session_set <session-id> <field> <value>
#   session_cleanup <session-id>

# Session storage directory
SESSION_DIR="${CLAUDE_SESSION_DIR:-${HOME}/.claude/skills/review-code/sessions}"

# Sanitize session ID or command name to prevent path traversal
# Args: $1 = string to sanitize
# Returns: sanitized string (only alphanumeric, hyphens, underscores)
sanitize_identifier() {
    local input="$1"

    # Only allow alphanumeric, hyphens, underscores
    if [[ ! "${input}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "ERROR: Invalid identifier: ${input} (only alphanumeric, -, _ allowed)" >&2
        return 1
    fi

    echo "${input}"
}

# Initialize a new session
# Args: $1 = command name (e.g., "review-code"), $2 = initial JSON data
# Returns: session ID
session_init() {
    local command_name="$1"
    local initial_data="$2"

    # Sanitize command name
    command_name=$(sanitize_identifier "${command_name}") || return 1

    # Create session ID using PID and timestamp for uniqueness
    local session_id
    session_id="${command_name}-$$-$(date +%s)"
    local command_dir="${SESSION_DIR}/${command_name}"
    local session_file="${command_dir}/${session_id}.json"

    # Create directories
    mkdir -p "${command_dir}"

    # Write initial data
    echo "${initial_data}" > "${session_file}"

    # Write session metadata
    jq -n \
        --arg id "${session_id}" \
        --arg cmd "${command_name}" \
        --arg file "${session_file}" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            session_id: $id,
            command: $cmd,
            file: $file,
            created: $created
        }' > "${command_dir}/${session_id}.meta.json"

    echo "${session_id}"
}

# Get session file path from session ID
# Args: $1 = session ID
# Returns: file path
session_file() {
    local session_id="$1"

    # Sanitize session ID to prevent path traversal
    session_id=$(sanitize_identifier "${session_id}") || return 1

    # Extract command name from session ID (format: command-name-pid-timestamp)
    # Need to remove the last two components (pid and timestamp)
    # First, remove timestamp: review-code-12345-1234567890 -> review-code-12345
    local without_timestamp="${session_id%-*}"
    # Then remove pid: review-code-12345 -> review-code
    local command_name="${without_timestamp%-*}"

    # Sanitize command name as well
    command_name=$(sanitize_identifier "${command_name}") || return 1

    local session_file="${SESSION_DIR}/${command_name}/${session_id}.json"

    # Verify the resolved path is still within SESSION_DIR (defense in depth)
    # Only perform canonical check if directory exists (allows checking for non-existent sessions)
    if [[ -d "$(dirname "${session_file}")" ]]; then
        local canonical_file
        canonical_file=$(cd "$(dirname "${session_file}")" && pwd -P)/$(basename "${session_file}")

        # Resolve SESSION_DIR to canonical path for comparison
        local canonical_session_dir
        canonical_session_dir=$(cd "${SESSION_DIR}" && pwd -P)

        if [[ "${canonical_file}" != "${canonical_session_dir}"/* ]]; then
            echo "ERROR: Session file path outside session directory" >&2
            return 1
        fi
    fi

    echo "${session_file}"
}

# Get entire session data
# Args: $1 = session ID
# Returns: JSON data
session_get_all() {
    local session_id="$1"
    local session_file
    session_file=$(session_file "${session_id}")

    if [[ ! -f "${session_file}" ]]; then
        echo "ERROR: Session not found: ${session_id}" >&2
        return 1
    fi

    cat "${session_file}"
}

# Get specific field from session
# Args: $1 = session ID, $2 = jq field path (e.g., ".status" or ".data.mode")
# Returns: field value
session_get() {
    local session_id="$1"
    local field="$2"

    session_get_all "${session_id}" | jq -r "${field}"
}

# Set field in session
# Args: $1 = session ID, $2 = field name, $3 = value
session_set() {
    local session_id="$1"
    local field="$2"
    local value="$3"
    local session_file
    session_file=$(session_file "${session_id}")

    if [[ ! -f "${session_file}" ]]; then
        echo "ERROR: Session not found: ${session_id}" >&2
        return 1
    fi

    # Update JSON file
    local temp_file="${session_file}.tmp"
    jq --arg val "${value}" ".${field} = \$val" "${session_file}" > "${temp_file}"
    mv "${temp_file}" "${session_file}"
}

# Update session with new JSON data (merge)
# Args: $1 = session ID, $2 = JSON data to merge
session_update() {
    local session_id="$1"
    local update_data="$2"
    local session_file
    session_file=$(session_file "${session_id}")

    if [[ ! -f "${session_file}" ]]; then
        echo "ERROR: Session not found: ${session_id}" >&2
        return 1
    fi

    # Merge JSON
    local temp_file="${session_file}.tmp"
    jq --argjson update "${update_data}" '. + $update' "${session_file}" > "${temp_file}"
    mv "${temp_file}" "${session_file}"
}

# Check if session exists
# Args: $1 = session ID
# Returns: 0 if exists, 1 if not
session_exists() {
    local session_id="$1"
    local session_file
    session_file=$(session_file "${session_id}")

    [[ -f "${session_file}" ]]
}

# Cleanup session
# Args: $1 = session ID
session_cleanup() {
    local session_id="$1"

    # Sanitize session ID
    session_id=$(sanitize_identifier "${session_id}") || return 1

    # Extract command name (same logic as session_file)
    local without_timestamp="${session_id%-*}"
    local command_name="${without_timestamp%-*}"

    # Sanitize command name
    command_name=$(sanitize_identifier "${command_name}") || return 1

    local command_dir="${SESSION_DIR}/${command_name}"

    # Remove session file and metadata
    rm -f "${command_dir}/${session_id}.json"
    rm -f "${command_dir}/${session_id}.meta.json"
}

# Cleanup old sessions (older than 1 hour)
# Args: $1 = command name (optional, if not provided cleans all commands)
session_cleanup_old() {
    local command_name="${1:-}"

    if [[ -z "${command_name}" ]]; then
        # Cleanup all commands
        find "${SESSION_DIR}" -name "*.json" -type f -mmin +60 -delete 2> /dev/null || true
        find "${SESSION_DIR}" -name "*.meta.json" -type f -mmin +60 -delete 2> /dev/null || true
    else
        # Sanitize command name
        command_name=$(sanitize_identifier "${command_name}") || return 1

        # Cleanup specific command
        local command_dir="${SESSION_DIR}/${command_name}"
        if [[ -d "${command_dir}" ]]; then
            find "${command_dir}" -name "*.json" -type f -mmin +60 -delete 2> /dev/null || true
            find "${command_dir}" -name "*.meta.json" -type f -mmin +60 -delete 2> /dev/null || true
        fi
    fi
}

# List active sessions for a command
# Args: $1 = command name
session_list() {
    local command_name="$1"

    # Sanitize command name
    command_name=$(sanitize_identifier "${command_name}") || return 1

    local command_dir="${SESSION_DIR}/${command_name}"

    if [[ ! -d "${command_dir}" ]]; then
        echo "[]"
        return
    fi

    # List all .meta.json files and combine into array
    local sessions=()
    while IFS= read -r meta_file; do
        if [[ -f "${meta_file}" ]]; then
            sessions+=("$(cat "${meta_file}")")
        fi
    done < <(find "${command_dir}" -name "*.meta.json" -type f 2> /dev/null || true)

    # Combine into JSON array
    if [[ ${#sessions[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${sessions[@]}" | jq -s '.'
    fi
}

# Functions are available when sourced (no export needed)
