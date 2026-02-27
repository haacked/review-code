#!/usr/bin/env bash
# Determine the correct handler file based on parsed arguments and output its contents.
# Called via dynamic context injection (!` `) in SKILL.md to pre-load the handler
# at skill invocation time, eliminating a runtime Read tool call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Parse arguments to determine mode by running parse-review-arg.sh.
# Discard stderr so that warnings (branch divergence, multiple PRs) don't
# corrupt the JSON on stdout. Errors are detected via exit code instead.
parse_exit=0
parse_result=$("${SCRIPT_DIR}/parse-review-arg.sh" "$@" 2> /dev/null) || parse_exit=$?

# Determine which handler to load based on the parsed mode.
# Error mode (non-zero exit) gets no handler since SKILL.md handles errors via PARSE_RESULT.
handler=""
if [[ $parse_exit -ne 0 ]]; then
    echo "<!-- No handler loaded: argument parsing returned an error. See PARSE_RESULT above. -->"
    exit 0
elif echo "${parse_result}" | jq -e '.mode == "learn"' > /dev/null 2>&1; then
    handler="${SKILL_DIR}/handlers/learn.md"
elif echo "${parse_result}" | jq -e '.find_mode == "true"' > /dev/null 2>&1; then
    handler="${SKILL_DIR}/handlers/find.md"
else
    handler="${SKILL_DIR}/handlers/review.md"
fi

# Output the handler content
if [[ -f "${handler}" ]]; then
    cat "${handler}"
else
    echo "ERROR: Handler file not found: ${handler}" >&2
    exit 1
fi
