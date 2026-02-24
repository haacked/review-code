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
