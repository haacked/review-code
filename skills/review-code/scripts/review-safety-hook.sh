#!/usr/bin/env bash
# review-safety-hook.sh - PreToolUse hook that blocks direct GitHub review operations
#
# The review-code skill must use create-draft-review.sh for all GitHub review
# operations. This hook enforces that by blocking direct gh CLI and API calls
# that would bypass the script's safety guarantees (pending vs submitted state,
# duplicate review detection, etc.).
#
# Blocked patterns:
#   - gh pr review                          (submits/creates reviews directly)
#   - gh api on a PR's reviews endpoints    (bypasses create-draft-review.sh)
#   - gh api on a single review comment     (can delete a published comment)
#   - GraphQL review and comment mutations  (the other transport for the same)
#
# Input: JSON on stdin (Claude Code PreToolUse hook format)
# Output: JSON with permissionDecision (deny or allow)

set -euo pipefail

deny() {
    jq -n --arg reason "$1" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $reason
        }
    }'
    exit 0
}

input=$(cat)
# Newlines are flattened to spaces before any matching below. Every check greps
# the command, and grep tests one line at a time, so a mutation split across
# lines would put "gh api" and the endpoint on different lines and match none of
# the patterns. Both spellings that get written by hand are multi-line: a
# GraphQL query in a quoted heredoc-style string, and a REST call continued with
# a trailing backslash.
command=$(echo "$input" | jq -r '.tool_input.command // ""' | tr '\n' ' ')

# Allow empty commands (shouldn't happen, but be safe)
if [[ -z "$command" ]]; then
    exit 0
fi

# Block direct gh pr review commands
if echo "$command" | grep -qE '\bgh\s+pr\s+review\b'; then
    deny "Direct gh pr review is blocked during code review. Use create-draft-review.sh instead, which ensures reviews stay in PENDING state and handles duplicate detection."
fi

# Block direct gh api calls to review endpoints
# The PR segment is [^/]+ rather than a number, so pulls/$PR/reviews is caught.
if echo "$command" | grep -qE '\bgh\s+api\b.*\brepos/[^/]+/[^/]+/pulls/[^/]+/reviews\b'; then
    deny "Direct GitHub API calls to review endpoints are blocked during code review. Use create-draft-review.sh instead."
fi

# Block direct calls to the single-review-comment endpoints, whatever the
# method. Matching the verb is not worth attempting: -X DELETE, --method DELETE,
# flag order and a shell variable in place of the verb all defeat it. Blocking
# reads too costs nothing, because GET on a pending comment 404s anyway and
# amend-pending-review.sh is the sanctioned way to list them. The pattern has no
# trailing id class on purpose, so pulls/comments/$id is caught as well as a
# literal number. It does not match pulls/<n>/comments or the reply endpoint
# pulls/<n>/comments/<id>/replies, neither of which contains "pulls/comments/".
if echo "$command" | grep -qE '\bgh\s+api\b.*\brepos/[^/]+/[^/]+/pulls/comments/'; then
    deny "Direct GitHub API calls to review comment endpoints are blocked during code review. Use amend-pending-review.sh to list, reword, or drop comments in your pending review."
fi

# Rewording a pending comment only works over GraphQL, so the REST pattern above
# would miss it entirely and the hole would simply move to the new transport.
# submitPullRequestReview and addPullRequestReview publish every pending comment
# at once and cannot be undone; the REST pattern above already denies the same
# action on /pulls/<n>/reviews, so leaving them out here enforced "never submit
# on the user's behalf" on one transport only.
# The pattern matches every add, update, delete, submit, or dismiss mutation
# whose name continues with PullRequestReview, which takes in the Comment and
# Thread variants. A list of exact names let deletePullRequestReview,
# updatePullRequestReview, and dismissPullRequestReview through.
# The three parts are separate matches because their order varies: gh accepts
# flags before the endpoint, and the query can sit in a variable set first.
# resolveReviewThread is deliberately absent: resolve-review-threads.sh is the
# sanctioned path for that and agents are not the ones calling it directly.
is_graphql_call=false
if echo "$command" | grep -qE '\bgh\s+api\b' && echo "$command" | grep -qE '\bgraphql\b'; then
    is_graphql_call=true
fi
if [[ "$is_graphql_call" == true ]] && echo "$command" | grep -qE '(add|update|delete|submit|dismiss)PullRequestReview'; then
    deny "Direct GraphQL mutations on reviews and review comments are blocked during code review. Use amend-pending-review.sh to reword or drop comments in your pending review, or to discard it. Never submit a review; that is the user's call."
fi

# The hook sees only the command text, so it cannot check a query that gh reads
# from a file with query=@path or --input.
if [[ "$is_graphql_call" == true ]] && echo "$command" | grep -qE '(query=@|--input\b)'; then
    deny "GraphQL calls that read the query from a file are blocked during code review, because this hook cannot check them. Put the query in the command, or use the review-code scripts."
fi

# Allow everything else
exit 0
