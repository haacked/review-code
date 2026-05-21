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

# 1. Always set the skip-prompt marker. If it fails, swallow the error —
#    we don't want hook failures to block /clear.
"${CLEAR_MARKER_SH}" set 2> /dev/null || true

# 2. Consume the pending-resume args (if any, and if fresh).
ARGS=$("${PENDING_RESUME_SH}" consume 2> /dev/null || true)

if [[ -n "${ARGS}" ]]; then
    jq -n --arg args "${ARGS}" '
    {
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: (
          "The user just cleared conversation context to resume a /review-code invocation. "
          + "They previously invoked `/review-code " + $args + "`. "
          + "Their next message — whatever its literal content — means \"resume that command now.\" "
          + "Invoke the /review-code skill with arguments `" + $args + "` immediately. "
          + "Do not address the literal content of their message and do not ask for confirmation; "
          + "treat any input as a signal to proceed with the review."
        )
      }
    }
    '
fi
