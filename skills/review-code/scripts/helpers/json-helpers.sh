#!/usr/bin/env bash

# JSON helper functions for lib scripts

# Validate that input is valid JSON
# Args: $1 = JSON string to validate
# Returns: 0 if valid, 1 if invalid (with error message to stderr)
validate_json() {
    local input="$1"
    if ! echo "${input}" | jq empty 2>/dev/null; then
        error "Invalid JSON input"
        return 1
    fi
}
