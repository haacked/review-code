#!/usr/bin/env bash
# SessionStart hook (matcher: "clear") for /review-code.
#
# Fires when the user runs /clear. Does two things:
#
# 1. Always: writes the skip-prompt marker so /review-code's next
#    pre-flight prompt is skipped instead of looping forever.
#
# 2. If the user picked "clear and resume" in a recent /review-code
#    invocation: emits SessionStart additionalContext that instructs
#    Claude to auto-invoke /review-code with the original args on the
#    user's next message. This is the closest interactive Claude Code
#    gets to "clear AND review" in one step — Claude can't act until
#    the user submits something, but the user only has to send any
#    message (e.g. "go") and the review starts with the original args.
#
# Hook output schema:
#   { "hookSpecificOutput": { "hookEventName": "SessionStart",
#     "additionalContext": "..." } }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAR_MARKER_SH="${SCRIPT_DIR}/clear-marker.sh"
PENDING_RESUME_SH="${SCRIPT_DIR}/pending-resume.sh"
LOG_FILE="${REVIEW_CODE_HOOK_LOG:-${HOME}/.claude/skills/review-code/sessions/.session-clear-hook.log}"

# Append one line per invocation so we can confirm the hook actually fires
# on /clear and inspect what it emitted. Bounded to ~50 entries.
log_line() {
    local msg="$1"
    mkdir -p "$(dirname "${LOG_FILE}")"
    printf '%s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${msg}" >> "${LOG_FILE}"
    if [[ -f "${LOG_FILE}" ]]; then
        tail -50 "${LOG_FILE}" > "${LOG_FILE}.tmp" 2> /dev/null && mv "${LOG_FILE}.tmp" "${LOG_FILE}" || true
    fi
}

log_line "fired (cwd=$(pwd))"

# 1. Always set the skip-prompt marker. If it fails, swallow the error —
#    we don't want hook failures to block /clear.
"${CLEAR_MARKER_SH}" set 2> /dev/null || true

# 2. Consume the pending-resume args (if any, and if fresh). Use the exit
#    code to decide whether to inject — `pending-resume.sh consume` exits 0
#    only when there was a fresh pending entry, even if its args were empty
#    (a no-args /review-code invocation is still worth auto-resuming).
if ARGS=$("${PENDING_RESUME_SH}" consume 2> /dev/null); then
    log_line "consumed pending-resume (args='${ARGS}') — emitting additionalContext"
    jq -n --arg args "${ARGS}" '
    {
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: (
          ("/review-code" + (if $args == "" then "" else " " + $args end)) as $cmd |
          "RESUME REQUEST — non-negotiable: the user just ran /clear immediately after picking \"clear and resume\" in the /review-code pre-flight prompt. "
          + "Their previous invocation was `" + $cmd + "`"
          + (if $args == "" then " (no arguments — the default review of local/branch changes). " else ". " end)
          + "Their next message — whatever its literal text — is the agreed-upon trigger to proceed; treat it as if they had typed `" + $cmd + "` again. "
          + "Your first action on the next turn MUST be to invoke the review-code skill via the Skill tool, passing args=\"" + $args + "\". "
          + "Do not respond to the literal content of their next message, do not ask for confirmation, and do not offer alternatives. "
          + "If for any reason you cannot invoke the skill, say so explicitly and quote this resume request — do not silently default to a normal response."
        )
      }
    }
    '
else
    log_line "no pending-resume found — skip-prompt marker set, no additionalContext"
fi
