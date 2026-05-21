#!/usr/bin/env bash
# Idempotently install/uninstall a global SessionStart hook in
# ~/.claude/settings.json that fires on `/clear`. The hook writes a marker
# so the /review-code skill can detect "user just cleared" on its next
# invocation and skip the pre-flight prompt instead of looping.
#
# Why this is global and not in SKILL.md frontmatter: skill-frontmatter
# hooks are scoped to skill lifetime, so they don't fire after /clear when
# the skill isn't loaded. SessionStart needs to fire before the skill loads,
# which means a global registration.
#
# Identity: we identify our hook entry by its exact `command` string. Install
# strips any matching entry first then appends, so repeated installs converge
# on a single entry. Uninstall removes the same entry. Both operations
# preserve unrelated hooks the user or other tools may have configured.
#
# Usage:
#   manage-session-hook.sh install
#   manage-session-hook.sh uninstall

set -euo pipefail

SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-${HOME}/.claude/settings.json}"
HOOK_COMMAND="${REVIEW_CODE_HOOK_COMMAND:-${HOME}/.claude/skills/review-code/scripts/clear-marker.sh set}"

read_settings() {
    if [[ -f "${SETTINGS_FILE}" ]]; then
        cat "${SETTINGS_FILE}"
    else
        echo "{}"
    fi
}

write_settings() {
    local new_content="$1"
    mkdir -p "$(dirname "${SETTINGS_FILE}")"
    local tmp="${SETTINGS_FILE}.tmp.$$"
    printf '%s\n' "${new_content}" > "${tmp}"
    mv "${tmp}" "${SETTINGS_FILE}"
}

# Strip our hook entry from .hooks.SessionStart, dropping any blocks whose
# `hooks` array becomes empty as a result. Returns full settings JSON.
strip_our_hook() {
    jq --arg cmd "${HOOK_COMMAND}" '
        if (.hooks // {}).SessionStart then
            .hooks.SessionStart |= (
                map(
                    if has("hooks") then
                        .hooks |= map(select((.command // "") != $cmd))
                    else . end
                )
                | map(select((.hooks // []) | length > 0))
            )
        else . end
    '
}

cmd_install() {
    local updated
    updated=$(read_settings | strip_our_hook | jq --arg cmd "${HOOK_COMMAND}" '
        .hooks //= {} |
        .hooks.SessionStart //= [] |
        .hooks.SessionStart += [{
            matcher: "clear",
            hooks: [{ type: "command", command: $cmd }]
        }]
    ')
    write_settings "${updated}"
}

cmd_uninstall() {
    local updated
    updated=$(read_settings | strip_our_hook | jq '
        if (.hooks // {}).SessionStart and ((.hooks.SessionStart | length) == 0) then
            del(.hooks.SessionStart)
        else . end
        | if (.hooks // null) == {} then del(.hooks) else . end
    ')
    write_settings "${updated}"
}

main() {
    local subcommand="${1:-}"
    case "${subcommand}" in
        install)
            cmd_install
            ;;
        uninstall)
            cmd_uninstall
            ;;
        *)
            echo "ERROR: Unknown subcommand: '${subcommand}'. Usage: $0 {install|uninstall}" >&2
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
