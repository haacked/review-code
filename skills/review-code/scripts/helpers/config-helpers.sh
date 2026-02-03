#!/bin/bash
# Configuration loading helpers
# Provides safe configuration file loading without code execution risks

# Safely load configuration from file
# Usage: load_config_safely "/path/to/config.env"
#
# This function parses configuration files containing KEY=VALUE pairs
# without using 'source', which prevents arbitrary code execution.
# Only whitelisted configuration keys are accepted.
#
# Supported configuration keys:
#   - REVIEW_ROOT_PATH: Root directory for review files
#   - CONTEXT_PATH: Path to context files
#   - DIFF_CONTEXT_LINES: Number of context lines in diffs
#
# Returns:
#   0 on success
#   1 on security violation (wrong owner or world-writable)
load_config_safely() {
    local config_file="$1"

    # Exit successfully if config file doesn't exist
    [[ ! -f "${config_file}" ]] && return 0

    # Validate file permissions for security
    local file_owner
    local file_perms

    if [[ "${OSTYPE}" == "darwin"* ]]; then
        # macOS
        file_owner=$(stat -f '%u' "${config_file}" 2> /dev/null)
        file_perms=$(stat -f '%Lp' "${config_file}" 2> /dev/null)
    else
        # Linux
        file_owner=$(stat -c '%u' "${config_file}" 2> /dev/null)
        file_perms=$(stat -c '%a' "${config_file}" 2> /dev/null)
    fi

    # Config must be owned by current user
    # shellcheck disable=SC2312  # id command failure is critical and will be caught
    if [[ "${file_owner}" != "$(id -u)" ]]; then
        error "Config file not owned by current user: ${config_file}"
        return 1
    fi

    # Config must not be world-writable
    local world_perms=$((file_perms % 10))
    if [[ $((world_perms & 2)) -ne 0 ]]; then
        error "Config file is world-writable: ${config_file}"
        error "Fix with: chmod o-w ${config_file}"
        return 1
    fi

    # Parse configuration file safely
    while IFS='=' read -r key value; do
        # Skip comments (lines starting with #)
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue

        # Skip empty lines
        [[ -z "${key}" ]] && continue

        # Validate key format: must be uppercase alphanumeric with underscores
        # This prevents command injection via malformed keys
        if [[ ! "${key}" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            continue
        fi

        # Remove surrounding quotes from value if present
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        # Whitelist allowed configuration keys
        # Only these keys will be set as environment variables
        case "${key}" in
            REVIEW_ROOT_PATH)
                export REVIEW_ROOT_PATH="${value}"
                ;;
            CONTEXT_PATH)
                export CONTEXT_PATH="${value}"
                ;;
            DIFF_CONTEXT_LINES)
                export DIFF_CONTEXT_LINES="${value}"
                ;;
            *)
                # Unknown keys are silently ignored for forward compatibility
                ;;
        esac
    done < "${config_file}"

    return 0
}

# Get the review root path from configuration
# Usage: review_root=$(get_review_root)
#
# Loads the REVIEW_ROOT_PATH from the configuration file if it exists,
# otherwise returns the default path ~/dev/ai/reviews
#
# Returns:
#   The review root path on stdout
get_review_root() {
    local review_root="${HOME}/dev/ai/reviews"
    local config_file=""

    if [[ -f "${HOME}/.claude/skills/review-code/.env" ]]; then
        config_file="${HOME}/.claude/skills/review-code/.env"
    elif [[ -f "${HOME}/.claude/review-code.env" ]]; then
        config_file="${HOME}/.claude/review-code.env"
    fi

    if [[ -n "${config_file}" ]]; then
        load_config_safely "${config_file}"
        review_root="${REVIEW_ROOT_PATH:-${HOME}/dev/ai/reviews}"
    fi

    echo "${review_root}"
}
