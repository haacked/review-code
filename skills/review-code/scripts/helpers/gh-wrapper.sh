#!/usr/bin/env bash
# Wrap gh CLI to prevent debug output when DEBUG is set in the environment.
# The gh CLI interprets any non-empty DEBUG env var as a signal to emit verbose
# output, which interferes with scripts that parse gh's stdout.

# Guard against being sourced more than once per process (review-orchestrator.sh
# sources this directly, then again transitively via git-helpers.sh).
[[ -n "${_GH_WRAPPER_SOURCED:-}" ]] && return
_GH_WRAPPER_SOURCED=1

if command -v gh > /dev/null 2>&1; then
    gh() {
        DEBUG= command gh "$@"
    }
fi
