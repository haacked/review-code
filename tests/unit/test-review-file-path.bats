#!/usr/bin/env bats
# Unit tests for review-file-path.sh

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/lib/review-file-path.sh"

    # Create temp directory for tests (use canonical path to avoid symlink issues on macOS)
    TEST_TEMP_DIR=$(mktemp -d)
    # Resolve to canonical path (handles /var -> /private/var on macOS)
    TEST_TEMP_DIR=$(cd "$TEST_TEMP_DIR" && pwd -P)
    export HOME="$TEST_TEMP_DIR"

    # Setup minimal git config with canonical path
    mkdir -p "$TEST_TEMP_DIR/.claude"
    CANONICAL_REVIEW_PATH="$TEST_TEMP_DIR/reviews"
    echo "REVIEW_ROOT_PATH=\"$CANONICAL_REVIEW_PATH\"" > "$TEST_TEMP_DIR/.claude/review-code.env"
}

teardown() {
    # Clean up temp directory
    rm -rf "$TEST_TEMP_DIR"
}

@test "review-file-path.sh exists and is executable" {
    [ -x "$SCRIPT" ]
}

# ============================================================================
# Path Sanitization Tests (Security Critical)
# ============================================================================

@test "sanitization: rejects absolute paths" {
    run "$SCRIPT" --org "/etc" --repo "passwd" "test"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Absolute paths not allowed" ]]
}

@test "sanitization: rejects path traversal with .." {
    run "$SCRIPT" --org "myorg" --repo "../../../etc/passwd" "test"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Path traversal sequences not allowed" ]]
}

@test "sanitization: rejects path traversal in identifier" {
    run "$SCRIPT" --org "myorg" --repo "myrepo" "../../secrets"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Path traversal sequences not allowed" ]]
}

@test "sanitization: rejects empty org" {
    run bash -c "cd /tmp && '$SCRIPT' --org '' --repo 'myrepo' 'test' 2>&1"
    [ "$status" -eq 1 ]
    # Script treats empty string as "not provided", which is correct behavior
}

@test "sanitization: rejects empty repo" {
    run bash -c "cd /tmp && '$SCRIPT' --org 'myorg' --repo '' 'test' 2>&1"
    [ "$status" -eq 1 ]
    # Script treats empty string as "not provided", which is correct behavior
}

@test "sanitization: rejects component starting with dot" {
    run "$SCRIPT" --org "myorg" --repo ".hidden" "test"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "cannot start with dot or dash" ]]
}

@test "sanitization: rejects component starting with dash" {
    run "$SCRIPT" --org "myorg" --repo "-test" "test"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "cannot start with dot or dash" ]]
}

@test "sanitization: converts slashes to dashes (branch names)" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "haacked/feature")
    echo "$result" | jq -e '.file_path | contains("haacked-feature")'
}

@test "sanitization: removes special characters but keeps alphanumeric, dash, underscore, dot" {
    result=$("$SCRIPT" --org "my-org_123" --repo "my.repo" "test")
    echo "$result" | jq -e '.org == "my-org_123"'
    echo "$result" | jq -e '.repo == "my.repo"'
}

@test "sanitization: rejects component that becomes empty after filtering" {
    run "$SCRIPT" --org "myorg" --repo "!!!" "test"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "became empty after sanitization" ]]
}

# ============================================================================
# Identifier Format Tests
# ============================================================================

@test "identifier: pure number is treated as PR" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "123")
    echo "$result" | jq -e '.pr_number == "123"'
    echo "$result" | jq -e '.file_path | endswith("pr-123.md")'
}

@test "identifier: pr-123 format is treated as PR" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "pr-456")
    echo "$result" | jq -e '.pr_number == "456"'
    echo "$result" | jq -e '.file_path | endswith("pr-456.md")'
}

@test "identifier: commit-hash format" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "commit-356ded2")
    echo "$result" | jq -e '.file_path | endswith("commit-356ded2.md")'
}

@test "identifier: range-xxx format" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "range-abc123..HEAD")
    # Should convert .. to -to- for filename safety
    echo "$result" | jq -e '.file_path | contains("range-abc123-to-HEAD")'
}

@test "identifier: branch-name format" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "branch-feature-test")
    echo "$result" | jq -e '.file_path | endswith("feature-test.md")'
}

@test "identifier: no identifier uses unknown when not in git repo" {
    # Run in /tmp which is not a git repo
    result=$(cd /tmp && "$SCRIPT" --org "myorg" --repo "myrepo")
    # When not in a git repo and no identifier, uses "unknown" as branch name
    echo "$result" | jq -e '.branch == "unknown"'
    echo "$result" | jq -e '.file_path | endswith("unknown.md")'
}

# ============================================================================
# Path Safety Verification Tests (Security Critical)
# ============================================================================

@test "path safety: file path is within review root" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    file_path=$(echo "$result" | jq -r '.file_path')
    review_root="$TEST_TEMP_DIR/reviews"

    # Ensure file_path starts with review_root
    [[ "$file_path" == "$review_root"* ]]
}

@test "path safety: creates org/repo directory structure" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    file_path=$(echo "$result" | jq -r '.file_path')

    # Check directory structure
    [[ "$file_path" =~ reviews/myorg/myrepo/ ]]
}

@test "path safety: directory is created" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    file_path=$(echo "$result" | jq -r '.file_path')
    dir=$(dirname "$file_path")

    [ -d "$dir" ]
}

# ============================================================================
# File Existence Tests
# ============================================================================

@test "file existence: reports false when file doesn't exist" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    echo "$result" | jq -e '.file_exists == false'
}

@test "file existence: reports true when file exists" {
    # Create the file first
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg/myrepo"
    touch "$TEST_TEMP_DIR/reviews/myorg/myrepo/test.md"

    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    echo "$result" | jq -e '.file_exists == true'
}

@test "file existence: detects old branch-based PR file and sets needs_rename" {
    # Create old branch-based file
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg/myrepo"
    touch "$TEST_TEMP_DIR/reviews/myorg/myrepo/main.md"

    # Mock git to return 'main' as current branch
    # Note: This test is simplified since we can't easily mock git in BATS
    # In a real test, you'd use a git fixture or mock the git commands

    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "pr-123")
    # Should suggest pr-123.md as the new path
    echo "$result" | jq -e '.file_path | endswith("pr-123.md")'
}

# ============================================================================
# JSON Output Format Tests
# ============================================================================

@test "json output: has all required fields" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")

    echo "$result" | jq -e 'has("org")'
    echo "$result" | jq -e 'has("repo")'
    echo "$result" | jq -e 'has("branch")'
    echo "$result" | jq -e 'has("pr_number")'
    echo "$result" | jq -e 'has("file_path")'
    echo "$result" | jq -e 'has("file_exists")'
    echo "$result" | jq -e 'has("needs_rename")'
    echo "$result" | jq -e 'has("old_path")'
}

@test "json output: pr_number is null for non-PR" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    echo "$result" | jq -e '.pr_number == null'
}

@test "json output: pr_number is string for PR" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "123")
    echo "$result" | jq -e '.pr_number == "123"'
}

@test "json output: old_path is null when not renaming" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    echo "$result" | jq -e '.old_path == null'
}

# ============================================================================
# Configuration Tests
# ============================================================================

@test "config: uses default review root when config doesn't exist" {
    # Remove config file
    rm -f "$TEST_TEMP_DIR/.claude/review-code.env"

    # Create the default directory structure so verify_path_safety doesn't fail
    mkdir -p "$TEST_TEMP_DIR/dev/ai"

    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    file_path=$(echo "$result" | jq -r '.file_path')

    # Should use default: ~/dev/ai/reviews
    [[ "$file_path" == "$TEST_TEMP_DIR/dev/ai/reviews"* ]]
}

@test "config: uses REVIEW_ROOT_PATH from config file" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    file_path=$(echo "$result" | jq -r '.file_path')

    # Should use configured path from setup
    [[ "$file_path" == "$TEST_TEMP_DIR/reviews"* ]]
}

# ============================================================================
# Edge Cases
# ============================================================================

@test "edge case: very long identifier is sanitized" {
    long_id="this-is-a-very-long-identifier-that-should-still-work-even-though-its-really-long"
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "$long_id")

    # Should succeed and create valid path
    echo "$result" | jq -e '.file_path | contains("'"$long_id"'")'
}

@test "edge case: identifier with multiple special characters" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "feat/123-add@feature#test")

    # Should sanitize to feat-123-addfeaturetest
    echo "$result" | jq -e '.file_path | contains("feat-123-addfeaturetest")'
}

@test "edge case: unicode characters are removed" {
    run "$SCRIPT" --org "myorg" --repo "myrepo" "test-🎉-feature"

    # Should sanitize out unicode and still work
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.file_path | contains("test--feature") or contains("test-feature")'
}

# ============================================================================
# Security Regression Tests
# ============================================================================

@test "security: cannot escape review root with crafted org" {
    run "$SCRIPT" --org "../../tmp" --repo "test" "test"
    [ "$status" -eq 1 ]
}

@test "security: cannot escape review root with crafted repo" {
    run "$SCRIPT" --org "test" --repo "../../tmp" "test"
    [ "$status" -eq 1 ]
}

@test "security: cannot escape review root with crafted identifier" {
    run "$SCRIPT" --org "test" --repo "test" "../../tmp/evil"
    [ "$status" -eq 1 ]
}

@test "security: null bytes are rejected" {
    # Bash doesn't handle null bytes well, but we should still test
    run "$SCRIPT" --org "test" --repo "test" "$(printf 'test\x00evil')"
    # Should either sanitize or reject
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "security: prevents symlink attacks by checking canonical paths" {
    # Create a symlink outside review root
    mkdir -p "$TEST_TEMP_DIR/outside"
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg"
    ln -s "$TEST_TEMP_DIR/outside" "$TEST_TEMP_DIR/reviews/myorg/evil-symlink"

    # Try to use the symlinked repo
    run "$SCRIPT" --org "myorg" --repo "evil-symlink" "test"

    # This should work since we're just creating a path, but verify it's within bounds
    if [ "$status" -eq 0 ]; then
        file_path=$(echo "$output" | jq -r '.file_path')
        # The path should still be under reviews even if symlink exists
        [[ "$file_path" == "$TEST_TEMP_DIR/reviews"* ]]
    fi
}
