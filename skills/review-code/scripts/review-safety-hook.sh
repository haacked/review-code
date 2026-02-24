#!/usr/bin/env bash
# review-safety-hook.sh - PreToolUse hook that blocks direct GitHub review operations
#
# The review-code skill must use create-draft-review.sh for all GitHub review
# operations. This hook enforces that by blocking direct gh CLI and API calls
# that would bypass the script's safety guarantees (pending vs submitted state,
# duplicate review detection, etc.).
#
# Blocked patterns:
#   - gh pr review    (submits/creates reviews directly)
#   - gh api with review endpoints (bypasses create-draft-review.sh)
#
# Input: JSON on stdin (Claude Code PreToolUse hook format)
# Output: JSON with permissionDecision (deny or allow)

set -euo pipefail

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Allow empty commands (shouldn't happen, but be safe)
if [[ -z "$command" ]]; then
    exit 0
fi

# Block direct gh pr review commands
if echo "$command" | grep -qE '\bgh\s+pr\s+review\b'; then
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: "Direct gh pr review is blocked during code review. Use create-draft-review.sh instead, which ensures reviews stay in PENDING state and handles duplicate detection."
        }
    }'
    exit 0
fi

# Block direct gh api calls to review endpoints
if echo "$command" | grep -qE '\bgh\s+api\b.*\brepos/[^/]+/[^/]+/pulls/[0-9]+/reviews\b'; then
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: "Direct GitHub API calls to review endpoints are blocked during code review. Use create-draft-review.sh instead."
        }
    }'
    exit 0
fi

# Allow everything else
exit 0
