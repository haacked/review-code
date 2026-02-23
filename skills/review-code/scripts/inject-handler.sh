#!/usr/bin/env bash
# Determine the correct handler file based on parsed arguments and output its contents.
# Called via dynamic context injection (!` `) in SKILL.md to pre-load the handler
# at skill invocation time, eliminating a runtime Read tool call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Parse arguments to determine mode by running parse-review-arg.sh
parse_result=$("${SCRIPT_DIR}/parse-review-arg.sh" "$@" 2>&1) || true

# Determine which handler to load based on the parsed mode
handler=""
if echo "${parse_result}" | jq -e '.mode == "learn"' > /dev/null 2>&1; then
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
