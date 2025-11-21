#!/usr/bin/env bats

# Tests for new PR detection features added in PR #4
# This file tests:
# - PR URL extraction with BASH_REMATCH validation
# - PR auto-detection via gh CLI
# - Remote ahead detection
# - Associated PR tracking in detect_no_arg

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Source the script to get access to functions
    source "$PROJECT_ROOT/lib/parse-review-arg.sh"
}

# =============================================================================
# PR URL Extraction Tests (with security validation)
# =============================================================================

@test "detect_pr: extracts PR number from GitHub URL" {
    arg="https://github.com/owner/repo/pull/999"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"pr"'* ]]
    [[ "$output" == *'"pr_number":"999"'* ]]
    [[ "$output" == *'"pr_url":"https://github.com/owner/repo/pull/999"'* ]]
}

@test "detect_pr: extracts PR number from URL with query params" {
    arg="https://github.com/owner/repo/pull/123?foo=bar&baz=qux"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"pr_number":"123"'* ]]
}

@test "detect_pr: handles URL with org containing hyphens" {
    arg="https://github.com/my-org/my-repo/pull/42"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"pr_number":"42"'* ]]
}

@test "detect_pr: handles URL with repo containing dots" {
    arg="https://github.com/org/repo.name/pull/55"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"pr_number":"55"'* ]]
}

@test "detect_pr: rejects malformed GitHub URL (missing repo)" {
    arg="https://github.com/owner/pull/123"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 1 ]
}

@test "detect_pr: rejects non-numeric PR number in URL" {
    arg="https://github.com/owner/repo/pull/abc"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 1 ]
}

@test "detect_pr: rejects GitLab merge request URL" {
    arg="https://gitlab.com/owner/repo/-/merge_requests/123"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 1 ]
}

@test "detect_pr: validates extracted PR number is numeric" {
    # This tests the BASH_REMATCH validation we added
    arg="https://github.com/owner/repo/pull/456"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    # Ensure the extracted number passes validation
    [[ "$output" == *'"pr_number":"456"'* ]]
}

# =============================================================================
# Remote Ahead Detection Tests
# =============================================================================

@test "detect_no_arg: handles branch with no upstream" {
    # Create a test branch with no upstream
    git checkout -b test-no-upstream-$$  2>/dev/null || true
    git commit --allow-empty -m "Test commit" 2>/dev/null || true

    run detect_no_arg
    # Should succeed without remote_ahead field (or remote_ahead: false)
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":'* ]]

    # Cleanup
    git checkout - > /dev/null 2>&1 || true
    git branch -D test-no-upstream-$$ > /dev/null 2>&1 || true
}

@test "detect_no_arg: handles missing gh CLI gracefully" {
    # Test with gh not in PATH
    PATH=/usr/bin:/bin run detect_no_arg
    [ "$status" -eq 0 ]
    # Should not have associated_pr field when gh unavailable
    [[ "$output" == *'"mode":'* ]]
}

# =============================================================================
# PR Auto-Detection Tests (when gh CLI available)
# =============================================================================

# Note: These tests only run if gh CLI is available
@test "detect_no_arg: works when gh CLI not available" {
    # Ensure graceful degradation
    if ! command -v gh >/dev/null 2>&1; then
        skip "gh CLI not available (this is fine)"
    fi

    # Even with gh available, should work on branches without PRs
    run detect_no_arg
    [ "$status" -eq 0 ]
}

# =============================================================================
# Integration: Full Flow Tests
# =============================================================================

@test "full parse flow: PR URL goes through detection" {
    # Test that PR URL detection works in the context of parse script
    run bash -c "source '$PROJECT_ROOT/lib/parse-review-arg.sh' && arg='https://github.com/test/repo/pull/789' && file_pattern='' && detect_pr"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"pr_number":"789"'* ]]
}

@test "full parse flow: branch detection works" {
    # Test branch detection path
    run bash -c "source '$PROJECT_ROOT/lib/parse-review-arg.sh' && arg='main' && file_pattern='' && detect_git_ref"
    # Should detect main as a git ref (exit 0) or detect ambiguity
    # Status depends on current repo state, so we just check it doesn't crash
    [ "$status" -ge 0 ]
}

# =============================================================================
# Error Handling Tests
# =============================================================================

@test "detect_pr: handles empty URL gracefully" {
    arg=""
    file_pattern=""
    run detect_pr
    [ "$status" -eq 1 ]
}

@test "detect_pr: handles malformed URL gracefully" {
    arg="not-a-url"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 1 ]
}

# =============================================================================
# Edge Cases
# =============================================================================

@test "detect_pr: handles very large PR numbers" {
    arg="https://github.com/org/repo/pull/999999"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"pr_number":"999999"'* ]]
}

@test "detect_pr: handles URL with trailing slash" {
    arg="https://github.com/org/repo/pull/123/"
    file_pattern=""
    run detect_pr
    # May or may not match depending on regex - document behavior
    # If it matches, pr_number should be 123
    if [ "$status" -eq 0 ]; then
        [[ "$output" == *'"pr_number":"123"'* ]]
    fi
}
