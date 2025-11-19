#!/usr/bin/env bash

# Lightweight error handling functions for lib scripts
# These match the interface from bin/helpers/_utils.sh but are optimized
# for minimal overhead in library scripts that may be called frequently

# Get caller context for error messages
# Returns: "script:line (function)" or empty if unavailable
_get_caller_context() {
    if [ -n "${BASH_SOURCE[2]:-}" ]; then
        local script=$(basename "${BASH_SOURCE[2]}")
        local line="${BASH_LINENO[1]}"
        local func="${FUNCNAME[2]:-main}"
        echo "${script}:${line} (${func})"
    fi
}

# Print error to stderr in red with caller context
error() {
    local context
    context=$(_get_caller_context)
    if [ -n "$context" ]; then
        echo -e "\033[31mError: [$context] $*\033[0m" >&2
    else
        echo -e "\033[31mError: $*\033[0m" >&2
    fi
}

# Print error and exit
fatal() {
    error "$*"
    exit 1
}

# Print warning in yellow with caller context
warning() {
    local context
    context=$(_get_caller_context)
    if [ -n "$context" ]; then
        echo -e "\033[33mWarning: [$context] $*\033[0m" >&2
    else
        echo -e "\033[33mWarning: $*\033[0m" >&2
    fi
}

# Print info message (no color, goes to stdout)
info() {
    echo "$*"
}
