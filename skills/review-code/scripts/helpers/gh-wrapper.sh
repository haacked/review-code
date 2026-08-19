#!/usr/bin/env bash
# Wrap gh CLI to prevent debug output when DEBUG is set in the environment.
# The gh CLI interprets any non-empty DEBUG env var as a signal to emit verbose
# output, which interferes with scripts that parse gh's stdout.

# Guard against being sourced more than once per process (review-orchestrator.sh
# sources this directly, then again transitively via git-helpers.sh).
[[ -n "${_GH_WRAPPER_SOURCED:-}" ]] && return
_GH_WRAPPER_SOURCED=1

_GH_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/cli-timeout-helpers.sh
source "${_GH_WRAPPER_DIR}/cli-timeout-helpers.sh"

if command -v gh > /dev/null 2>&1; then
    gh() {
        # shellcheck disable=SC1007  # DEBUG= scrubs the variable for this command only
        DEBUG= command gh "$@"
    }
fi

# Run gh under a timeout. The timeout binary execs the gh binary directly,
# bypassing the gh() function above, so the env scrub is inlined here; keep
# it in sync with gh().
# Usage: gh_with_timeout <timeout_seconds> <gh_args...>
gh_with_timeout() {
    local timeout_secs="$1"
    shift
    run_with_timeout "${timeout_secs}" env DEBUG= gh "$@"
}
