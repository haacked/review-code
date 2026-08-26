#!/usr/bin/env bats
# Tests for review-safety-hook.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/review-safety-hook.sh"
}

# Helper to build hook input JSON for a given command
make_input() {
    local cmd="$1"
    printf '{"tool_input":{"command":"%s"}}' "$cmd"
}

# Same, for a command carrying newlines or double quotes. make_input pastes its
# argument straight between two quote characters, so either one produces JSON
# that jq rejects before the hook ever sees the command.
make_input_raw() {
    jq -nc --arg cmd "$1" '{tool_input: {command: $cmd}}'
}

# =============================================================================
# Blocked commands
# =============================================================================

@test "blocks gh pr review" {
    result=$(make_input "gh pr review 123 --approve" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks gh pr review with flags" {
    result=$(make_input "gh pr review 123 --comment --body 'looks good'" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks gh pr review with extra whitespace" {
    result=$(make_input "gh  pr  review 456" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks gh api to review endpoint" {
    result=$(make_input "gh api repos/posthog/posthog/pulls/123/reviews --method POST" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks gh api to review endpoint with different org/repo" {
    result=$(make_input "gh api repos/myorg/myrepo/pulls/456/reviews" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "block reason mentions create-draft-review.sh for gh pr review" {
    result=$(make_input "gh pr review 123" | bash "$SCRIPT")
    reason=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecisionReason')
    [[ "$reason" == *"create-draft-review.sh"* ]]
}

@test "block reason mentions create-draft-review.sh for gh api" {
    result=$(make_input "gh api repos/org/repo/pulls/1/reviews" | bash "$SCRIPT")
    reason=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecisionReason')
    [[ "$reason" == *"create-draft-review.sh"* ]]
}

# =============================================================================
# Allowed commands
# =============================================================================

@test "allows gh pr view" {
    result=$(make_input "gh pr view 123" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows gh pr list" {
    result=$(make_input "gh pr list --repo posthog/posthog" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows gh pr diff" {
    result=$(make_input "gh pr diff 123" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows gh pr checks" {
    result=$(make_input "gh pr checks 123" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows gh issue view" {
    result=$(make_input "gh issue view 123" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows create-draft-review.sh" {
    result=$(make_input "~/.claude/skills/review-code/scripts/create-draft-review.sh" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows submit-review.sh" {
    result=$(make_input "~/.claude/skills/review-code/scripts/submit-review.sh" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows other bash commands" {
    result=$(make_input "git diff HEAD~1" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows gh api to non-review endpoints" {
    result=$(make_input "gh api repos/org/repo/pulls/123/comments" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows empty command" {
    result=$(echo '{"tool_input":{}}' | bash "$SCRIPT")
    [ -z "$result" ]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "does not block gh pr review in a comment or echo" {
    # If someone echoes the text, grep will match it, but that's acceptable —
    # better to over-block than under-block for safety-critical operations
    result=$(make_input "echo 'do not run gh pr review'" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "exits 0 for allowed commands" {
    make_input "ls -la" | bash "$SCRIPT"
    [ $? -eq 0 ]
}

@test "exits 0 for blocked commands" {
    make_input "gh pr review 123" | bash "$SCRIPT"
    [ $? -eq 0 ]
}

# =============================================================================
# Single review comment endpoints (REST)
# =============================================================================

@test "blocks gh api DELETE on a single review comment" {
    result=$(make_input "gh api --method DELETE repos/org/repo/pulls/comments/123" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks the -X DELETE spelling too" {
    result=$(make_input "gh api -X DELETE repos/org/repo/pulls/comments/123" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks gh api PATCH on a single review comment" {
    result=$(make_input "gh api --method PATCH repos/org/repo/pulls/comments/123 -f body=x" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks a review comment endpoint built from a shell variable" {
    result=$(make_input 'gh api --method DELETE repos/$OWNER/$REPO/pulls/comments/$id' | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "block reason for a review comment endpoint names amend-pending-review.sh" {
    result=$(make_input "gh api --method DELETE repos/org/repo/pulls/comments/123" | bash "$SCRIPT")
    reason=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecisionReason')
    [[ "$reason" == *"amend-pending-review.sh"* ]]
}

@test "still allows the PR comments collection" {
    result=$(make_input "gh api repos/org/repo/pulls/123/comments" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "still allows replying to a review comment" {
    result=$(make_input "gh api --method POST repos/org/repo/pulls/123/comments/456/replies -f body=ok" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "allows amend-pending-review.sh" {
    result=$(make_input "~/.agents/skills/review-code/scripts/amend-pending-review.sh 123 --drop --comment-id 456" | bash "$SCRIPT")
    [ -z "$result" ]
}

# =============================================================================
# Review comment mutations (GraphQL)
# =============================================================================

@test "blocks a raw GraphQL comment reword" {
    result=$(make_input "gh api graphql -f query='mutation { updatePullRequestReviewComment(input: {}) { x } }'" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks a raw GraphQL addPullRequestReviewThread" {
    result=$(make_input "gh api graphql -f query='mutation { addPullRequestReviewThread(input: {}) { x } }'" | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "block reason for a GraphQL mutation names amend-pending-review.sh" {
    result=$(make_input "gh api graphql -f query='mutation { updatePullRequestReviewComment(input: {}) { x } }'" | bash "$SCRIPT")
    reason=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecisionReason')
    [[ "$reason" == *"amend-pending-review.sh"* ]]
}

@test "still allows the GraphQL thread resolution the append flow uses" {
    result=$(make_input "gh api graphql -f query='mutation { resolveReviewThread(input: {}) { x } }'" | bash "$SCRIPT")
    [ -z "$result" ]
}

@test "still allows an ordinary GraphQL query" {
    result=$(make_input "gh api graphql -f query='query { viewer { login } }'" | bash "$SCRIPT")
    [ -z "$result" ]
}

# Every spelling above is a single line. A mutation written across lines used to
# reach GitHub, because grep tests one line at a time and "gh api" then landed on
# a different line from the mutation name. The multi-line form is the one written
# by hand: reword_comment in amend-pending-review.sh spells its query this way.
@test "blocks a GraphQL comment reword written across lines" {
    result=$(make_input_raw 'gh api graphql -f query='"'"'
mutation {
  updatePullRequestReviewComment(input: {pullRequestReviewCommentId: "x", body: "y"}) { clientMutationId }
}'"'"'' | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks a GraphQL comment delete written across lines" {
    result=$(make_input_raw 'gh api graphql -f query='"'"'
mutation {
  deletePullRequestReviewComment(input: {id: "PRRC_x"}) { clientMutationId }
}'"'"'' | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks a review comment DELETE continued with a backslash" {
    result=$(make_input_raw 'gh api --method DELETE \
  repos/org/repo/pulls/comments/123' | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

# Submitting publishes every pending comment at once and cannot be undone. The
# REST spelling is already denied by the /pulls/<n>/reviews pattern, so leaving
# these two out of the mutation list enforced "never submit a review on the
# user's behalf" on one transport and not the other.
@test "blocks submitting a review over GraphQL" {
    result=$(make_input_raw 'gh api graphql -f query='"'"'mutation { submitPullRequestReview(input: {pullRequestReviewId: "x", event: APPROVE}) { clientMutationId } }'"'"'' | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "blocks creating and submitting a review over GraphQL" {
    result=$(make_input_raw 'gh api graphql -f query='"'"'mutation { addPullRequestReview(input: {pullRequestId: "x", event: APPROVE}) { clientMutationId } }'"'"'' | bash "$SCRIPT")
    decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "still allows a multi-line GraphQL query that mutates nothing" {
    result=$(make_input_raw 'gh api graphql -f query='"'"'
query {
  viewer { login }
}'"'"'' | bash "$SCRIPT")
    [ -z "$result" ]
}
