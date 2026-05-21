#!/usr/bin/env bash
# Stores the args a user wants to resume after /clear.
#
# When the /review-code pre-flight prompt fires and the user picks
# "clear and resume", the skill records the original $ARGUMENTS here.
# The SessionStart hook on /clear reads this file and emits
# additionalContext so Claude auto-invokes /review-code with those args
# on the user's next message.
#
# Usage:
#   pending-resume.sh set <args...>   # Record args (multi-arg form, joined with spaces)
#   pending-resume.sh set-string "arg string"   # Record a pre-joined string verbatim
#   pending-resume.sh get             # Print args (does NOT delete the file)
#   pending-resume.sh consume         # Print args, then delete the file
#   pending-resume.sh clear           # Delete the file

set -euo pipefail

MARKER_DIR="${REVIEW_CODE_MARKER_DIR:-${HOME}/.claude/skills/review-code/sessions}"
PENDING_RESUME_FILE="${MARKER_DIR}/.pending-resume"

# 10-minute TTL matches the clear-marker so a stale resume can't auto-fire
# the next time a user clears for unrelated reasons.
PENDING_RESUME_TTL_SECONDS=600

cmd_set() {
    mkdir -p "${MARKER_DIR}"
    printf '%s' "$*" > "${PENDING_RESUME_FILE}"
}

# Same as `set` but treats the first positional as a single pre-joined
# string. SKILL.md uses this form so we get the args verbatim from
# Claude's $ARGUMENTS expansion without word-splitting.
cmd_set_string() {
    mkdir -p "${MARKER_DIR}"
    printf '%s' "${1-}" > "${PENDING_RESUME_FILE}"
}

# Print mtime in epoch seconds; tries BSD then GNU stat.
file_mtime() {
    stat -f %m "${PENDING_RESUME_FILE}" 2> /dev/null \
        || stat -c %Y "${PENDING_RESUME_FILE}" 2> /dev/null
}

fresh_or_die() {
    [[ -f "${PENDING_RESUME_FILE}" ]] || return 1
    local mtime
    if ! mtime=$(file_mtime); then
        rm -f "${PENDING_RESUME_FILE}"
        return 1
    fi
    local now age
    now=$(date +%s)
    age=$((now - mtime))
    if ((age > PENDING_RESUME_TTL_SECONDS)); then
        rm -f "${PENDING_RESUME_FILE}"
        return 1
    fi
    return 0
}

cmd_get() {
    if fresh_or_die; then
        cat "${PENDING_RESUME_FILE}"
    fi
}

cmd_consume() {
    if fresh_or_die; then
        cat "${PENDING_RESUME_FILE}"
        rm -f "${PENDING_RESUME_FILE}"
    fi
}

cmd_clear() {
    rm -f "${PENDING_RESUME_FILE}"
}

main() {
    local subcommand="${1:-}"
    case "${subcommand}" in
        set)
            shift
            cmd_set "$@"
            ;;
        set-string)
            shift
            cmd_set_string "${1-}"
            ;;
        get)
            cmd_get
            ;;
        consume)
            cmd_consume
            ;;
        clear)
            cmd_clear
            ;;
        *)
            echo "ERROR: Unknown subcommand: '${subcommand}'. Usage: $0 {set|set-string|get|consume|clear}" >&2
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
