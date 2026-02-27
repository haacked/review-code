#!/usr/bin/env bash

# JSON helper functions for lib scripts

# Validate that input is valid JSON
# Args: $1 = JSON string to validate
# Returns: 0 if valid, 1 if invalid (with error message to stderr)
validate_json() {
    local input="$1"
    if ! echo "${input}" | jq empty 2> /dev/null; then
        error "Invalid JSON input"
        return 1
    fi
}

# Validate a required field extracted from JSON input.
# Outputs a JSON error object to stdout and returns 1 if the value is empty or
# the literal string "null" (which is what jq -r produces for missing keys).
# Args: $1 = value, $2 = field name
require_field() {
    local value="$1"
    local name="$2"

    if [[ -z "${value}" ]] || [[ "${value}" == "null" ]]; then
        jq -n --arg name "${name}" '{success: false, error: ("Missing " + $name)}'
        return 1
    fi
}
