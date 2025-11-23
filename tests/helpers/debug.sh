#!/usr/bin/env bash
# Debug helper for tests
# Usage: source tests/helpers/debug.sh

# Print debug information about the test environment
debug_test_env() {
    echo "=== Test Environment Debug ===" >&2
    echo "PWD: $PWD" >&2
    echo "HOME: $HOME" >&2
    echo "BASH_VERSION: $BASH_VERSION" >&2
    echo "TEST_TEMP_DIR: ${TEST_TEMP_DIR:-not set}" >&2
    echo "OSTYPE: $OSTYPE" >&2

    if [ -f "$HOME/.claude/review-code.env" ]; then
        echo "Config file exists at: $HOME/.claude/review-code.env" >&2
        echo "Config contents:" >&2
        cat "$HOME/.claude/review-code.env" >&2
    else
        echo "No config file at: $HOME/.claude/review-code.env" >&2
    fi

    if [ -n "${CANONICAL_REVIEW_PATH:-}" ]; then
        echo "CANONICAL_REVIEW_PATH: $CANONICAL_REVIEW_PATH" >&2
        echo "CANONICAL_REVIEW_PATH exists: $([ -d "$CANONICAL_REVIEW_PATH" ] && echo "yes" || echo "no")" >&2
    fi

    echo "Git config:" >&2
    { git config --global user.name || echo "No user.name"; } >&2
    { git config --global user.email || echo "No user.email"; } >&2

    echo "===========================" >&2
}

# Debug a specific variable value
debug_var() {
    local var_name="$1"
    local var_value="${!var_name}"
    echo "DEBUG: $var_name='$var_value' (length=${#var_value})" >&2
}

# Debug function call with arguments
debug_call() {
    echo "DEBUG: Calling $1 with args:" >&2
    shift
    local i=1
    for arg in "$@"; do
        echo "  arg$i='$arg' (length=${#arg})" >&2
        ((i++))
    done
}
