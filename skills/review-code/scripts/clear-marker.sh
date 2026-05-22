#!/usr/bin/env bash
# Pre-flight /clear marker for /review-code.
#
# Inputs/outputs:
#   set    — touch ${MARKER_DIR}/.pending-clear (created on demand)
#   check  — print "skip" and consume the marker if fresh (within TTL);
#            silent otherwise
#
# The SessionStart hook (session-clear-hook.sh) calls `set` on every /clear
# or session-start, and Step 2 of SKILL.md calls `check` before deciding
# whether to prompt the user about clearing context. The TTL bounds stale
# markers from an abandoned flow. Override the directory with
# REVIEW_CODE_MARKER_DIR for tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/date-helpers.sh
source "${SCRIPT_DIR}/helpers/date-helpers.sh"

MARKER_DIR="${REVIEW_CODE_MARKER_DIR:-${HOME}/.claude/skills/review-code/sessions}"
MARKER_FILE="${MARKER_DIR}/.pending-clear"
MARKER_TTL_SECONDS=600

cmd_set() {
    mkdir -p "${MARKER_DIR}"
    : > "${MARKER_FILE}"
}

cmd_check() {
    [[ -f "${MARKER_FILE}" ]] || return 0

    local mtime
    mtime=$(get_file_mtime "${MARKER_FILE}")
    if [[ -z "${mtime}" ]]; then
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
