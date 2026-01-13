#!/usr/bin/env bats
# Tests for pr-context.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
}

# =============================================================================
# gh CLI validation tests
# =============================================================================

@test "pr-context.sh: checks for gh CLI" {
    # Only run if gh is not installed
    if ! command -v gh &> /dev/null; then
        run "$PROJECT_ROOT/lib/pr-context.sh" 123
        [ "$status" -eq 1 ]
        [[ "$output" == *"gh CLI is not installed"* ]]
    else
        skip "gh CLI is installed"
    fi
}

# =============================================================================
# Usage validation tests
# =============================================================================

@test "pr-context.sh: requires PR identifier" {
    run "$PROJECT_ROOT/lib/pr-context.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

# =============================================================================
# parse_pr_identifier tests
# =============================================================================

@test "pr-context.sh: parses PR number" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && parse_pr_identifier '123'"
    [ "$status" -eq 0 ]
    [ "$output" = "|123" ]
}

@test "pr-context.sh: parses PR URL with org and repo" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && parse_pr_identifier 'https://github.com/PostHog/posthog/pull/456'"
    [ "$status" -eq 0 ]
    [ "$output" = "posthog|posthog|456" ]
}

@test "pr-context.sh: normalizes org to lowercase" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && parse_pr_identifier 'https://github.com/PostHog/posthog/pull/789'"
    [ "$status" -eq 0 ]
    [[ "$output" == "posthog"* ]]
}

@test "pr-context.sh: rejects invalid PR identifier" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && parse_pr_identifier 'invalid'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid PR identifier"* ]]
}

@test "pr-context.sh: extracts number from various URL formats" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && parse_pr_identifier 'https://github.com/owner/repo/pull/999'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"|999" ]]
}

# =============================================================================
# Command array safety tests
# =============================================================================

@test "pr-context.sh: fetch_pr_metadata uses array for command" {
    # Check that the function exists and doesn't execute unsafely
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && declare -f fetch_pr_metadata | grep -q 'gh_cmd=('"
    [ "$status" -eq 0 ]
}

@test "pr-context.sh: fetch_pr_diff uses array for command" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && declare -f fetch_pr_diff | grep -q 'gh_cmd=('"
    [ "$status" -eq 0 ]
}

@test "pr-context.sh: fetch_reviews uses array for command" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && declare -f fetch_reviews | grep -q 'gh_cmd=('"
    [ "$status" -eq 0 ]
}

@test "pr-context.sh: fetch_conversation_comments uses paginated API" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && declare -f fetch_conversation_comments | grep -q 'gh api --paginate'"
    [ "$status" -eq 0 ]
}

@test "pr-context.sh: fetch_inline_comments uses paginated API" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && declare -f fetch_inline_comments | grep -q 'gh api --paginate'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# URL extraction tests
# =============================================================================

@test "pr-context.sh: extracts org from GitHub URL" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && parse_pr_identifier 'https://github.com/myorg/myrepo/pull/42'"
    [ "$status" -eq 0 ]
    [[ "$output" == "myorg|"* ]]
}

@test "pr-context.sh: extracts repo from GitHub URL" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && parse_pr_identifier 'https://github.com/myorg/myrepo/pull/42'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"|myrepo|"* ]]
}

@test "pr-context.sh: extracts PR number from GitHub URL" {
    run bash -c "source '$PROJECT_ROOT/lib/pr-context.sh' && parse_pr_identifier 'https://github.com/myorg/myrepo/pull/42'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"|42" ]]
}
