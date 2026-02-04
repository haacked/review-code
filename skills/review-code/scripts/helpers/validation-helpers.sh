#!/usr/bin/env bash

# Validation helper functions for argument parsing

# Validate that a value is a positive integer
# Usage: require_positive_int <option_name> <value>
# Exits with error if validation fails
require_positive_int() {
    local option_name="$1"
    local value="$2"

    if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -le 0 ]]; then
        error "${option_name} must be a positive integer, got: \"${value}\""
        exit 1
    fi
}
