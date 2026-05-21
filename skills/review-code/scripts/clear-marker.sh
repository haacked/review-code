#!/usr/bin/env bash
# Pre-flight /clear marker — breaks the infinite-loop where the recommended
# option in Step 2 of SKILL.md ("Yes, clear and review") sends the user to
# /clear, but on re-invocation the skill has no way to know they just cleared
# and asks again, looping forever.
#
# Flow:
#   1. User runs /review-code; Step 2 asks "Clear conversation history?"
#   2. User picks "Yes, clear and review" → `clear-marker.sh set`, skill tells
#      user to /clear and re-invoke.
#   3. After /clear, user re-runs /review-code; Step 2 calls
#      `clear-marker.sh check`, finds a recent marker, consumes it, prints
#      "skip", and the skill proceeds directly to Step 3.
#
# The marker has a 10-minute TTL so abandoned markers expire and the prompt
# returns to its normal behavior. Override the directory with
# REVIEW_CODE_MARKER_DIR for tests.

set -euo pipefail

MARKER_DIR="${REVIEW_CODE_MARKER_DIR:-${HOME}/.claude/skills/review-code/sessions}"
MARKER_FILE="${MARKER_DIR}/.pending-clear"
MARKER_TTL_SECONDS=600

cmd_set() {
    mkdir -p "${MARKER_DIR}"
    : > "${MARKER_FILE}"
}

# stat flag differs between BSD (macOS) and GNU (Linux); try both.
marker_mtime() {
    stat -f %m "${MARKER_FILE}" 2> /dev/null \
        || stat -c %Y "${MARKER_FILE}" 2> /dev/null
}

cmd_check() {
    [[ -f "${MARKER_FILE}" ]] || return 0

    local mtime
    if ! mtime=$(marker_mtime); then
        # Couldn't read mtime — fail safe by removing the marker and not skipping.
        rm -f "${MARKER_FILE}"
        return 0
    fi

    local now age
    now=$(date +%s)
    age=$((now - mtime))

    # Consume the marker either way so a single "set" never satisfies multiple
    # invocations.
    rm -f "${MARKER_FILE}"

    if ((age <= MARKER_TTL_SECONDS)); then
        echo "skip"
    fi
}

main() {
    local subcommand="${1:-}"
    case "${subcommand}" in
        set)
            cmd_set
            ;;
        check)
            cmd_check
            ;;
        *)
            echo "ERROR: Unknown subcommand: '${subcommand}'. Usage: $0 {set|check}" >&2
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
