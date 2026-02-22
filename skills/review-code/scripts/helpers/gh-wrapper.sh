#!/usr/bin/env bash
# Wrap gh CLI to prevent debug output when DEBUG is set in the environment.
# The gh CLI interprets any non-empty DEBUG env var as a signal to emit verbose
# output, which interferes with scripts that parse gh's stdout.

if command -v gh > /dev/null 2>&1; then
    gh() {
        DEBUG= command gh "$@"
    }
fi
