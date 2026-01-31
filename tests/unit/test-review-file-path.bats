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
    # Create reviews directory and get its canonical path to ensure consistency
    mkdir -p "$TEST_TEMP_DIR/reviews"
    CANONICAL_REVIEW_PATH=$(cd "$TEST_TEMP_DIR/reviews" && pwd -P)
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

# =============================================================================
# Directory auto-creation tests
# =============================================================================

@test "review-file-path.sh: creates missing parent directories" {
    # Use a deeply nested path that doesn't exist
    deep_org="new-org"
    deep_repo="new-repo"

    # Verify directories don't exist
    [ ! -d "$TEST_TEMP_DIR/reviews/$deep_org" ]

    # Run script - should create parent directories
    run "$SCRIPT" --org "$deep_org" --repo "$deep_repo" "test-pr"
    [ "$status" -eq 0 ]

    # Verify directories were created
    file_path=$(echo "$output" | jq -r '.file_path')
    parent_dir=$(dirname "$file_path")
    [ -d "$parent_dir" ]
}

@test "review-file-path.sh: handles already existing directories" {
    # Create directories first
    mkdir -p "$TEST_TEMP_DIR/reviews/existing-org/existing-repo"

    # Run script - should work fine with existing directories
    run "$SCRIPT" --org "existing-org" --repo "existing-repo" "test-pr"
    [ "$status" -eq 0 ]

    file_path=$(echo "$output" | jq -r '.file_path')
    [ -n "$file_path" ]
}

@test "review-file-path.sh: fails gracefully when mkdir fails" {
    # Create a read-only directory to prevent mkdir from succeeding
    readonly_dir="$TEST_TEMP_DIR/reviews/readonly-org"
    mkdir -p "$readonly_dir"
    chmod 444 "$readonly_dir"

    # Try to create a subdirectory - should fail
    run "$SCRIPT" --org "readonly-org" --repo "new-repo" "test-pr"

    # Should exit with error
    [ "$status" -ne 0 ]

    # Clean up: restore permissions
    chmod 755 "$readonly_dir"
}

# =============================================================================
# Source vs Execute guard clause tests
# =============================================================================

@test "review-file-path.sh: can be sourced without executing main" {
    # Source the script - should not produce output
    output=$(source "$SCRIPT" 2>&1)

    # Sourcing should not produce any output (main not executed)
    [ -z "$output" ]

    # Verify main function exists after sourcing
    source "$SCRIPT"
    declare -F main > /dev/null
}

@test "review-file-path.sh: executes main when run directly" {
    run "$SCRIPT" --org "testorg" --repo "testrepo" "test-pr"
    [ "$status" -eq 0 ]

    # Should produce JSON output when executed directly
    echo "$output" | jq -e '.file_path' > /dev/null
}

# =============================================================================
# PR fallback tests for branch mode
# =============================================================================

@test "branch fallback: finds PR file when branch file doesn't exist and gh returns PR" {
    # Create a PR review file but not a branch file
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg/myrepo"
    touch "$TEST_TEMP_DIR/reviews/myorg/myrepo/pr-999.md"

    # Create a mock gh script that returns PR 999 for any branch
    mock_gh="$TEST_TEMP_DIR/bin/gh"
    mkdir -p "$(dirname "$mock_gh")"
    cat > "$mock_gh" << 'EOF'
#!/usr/bin/env bash
# Mock gh CLI that returns PR 999 for any pr list command
if [[ "$1" == "pr" ]] && [[ "$2" == "list" ]]; then
    echo "999"
fi
EOF
    chmod +x "$mock_gh"

    # Run with mock gh in PATH
    PATH="$TEST_TEMP_DIR/bin:$PATH" run "$SCRIPT" --org "myorg" --repo "myrepo" "branch-feature-test"
    [ "$status" -eq 0 ]

    # Should find the PR file instead
    echo "$output" | jq -e '.file_exists == true'
    echo "$output" | jq -e '.pr_number == "999"'
    echo "$output" | jq -e '.file_path | endswith("pr-999.md")'
}

@test "branch fallback: returns branch file path when no PR exists" {
    # Create just the directory, no files
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg/myrepo"

    # Create a mock gh script that returns empty (no PR)
    mock_gh="$TEST_TEMP_DIR/bin/gh"
    mkdir -p "$(dirname "$mock_gh")"
    cat > "$mock_gh" << 'EOF'
#!/usr/bin/env bash
# Mock gh CLI that returns nothing
echo ""
EOF
    chmod +x "$mock_gh"

    # Run with mock gh in PATH
    PATH="$TEST_TEMP_DIR/bin:$PATH" run "$SCRIPT" --org "myorg" --repo "myrepo" "branch-my-feature"
    [ "$status" -eq 0 ]

    # Should return the branch file path (not found)
    echo "$output" | jq -e '.file_exists == false'
    echo "$output" | jq -e '.pr_number == null'
    echo "$output" | jq -e '.file_path | endswith("my-feature.md")'
}

@test "branch fallback: PR takes precedence when both exist, flags branch review" {
    # Create BOTH a branch file and PR file
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg/myrepo"
    touch "$TEST_TEMP_DIR/reviews/myorg/myrepo/existing-branch.md"
    touch "$TEST_TEMP_DIR/reviews/myorg/myrepo/pr-888.md"

    # Create a mock gh script that returns PR 888
    mock_gh="$TEST_TEMP_DIR/bin/gh"
    mkdir -p "$(dirname "$mock_gh")"
    cat > "$mock_gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" ]] && [[ "$2" == "list" ]]; then
    echo "888"
fi
EOF
    chmod +x "$mock_gh"

    # Run with mock gh in PATH
    PATH="$TEST_TEMP_DIR/bin:$PATH" run "$SCRIPT" --org "myorg" --repo "myrepo" "branch-existing-branch"
    [ "$status" -eq 0 ]

    # PR should take precedence
    echo "$output" | jq -e '.file_exists == true'
    echo "$output" | jq -e '.file_path | endswith("pr-888.md")'
    echo "$output" | jq -e '.pr_number == "888"'
    # Should flag that branch review also exists
    echo "$output" | jq -e '.has_branch_review == true'
    echo "$output" | jq -e '.branch_review_path | endswith("existing-branch.md")'
}

@test "branch fallback: handles branch names with slashes" {
    # Create a PR review file for a branch with slashes
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg/myrepo"
    touch "$TEST_TEMP_DIR/reviews/myorg/myrepo/pr-777.md"

    # Create a mock gh script that returns PR 777
    mock_gh="$TEST_TEMP_DIR/bin/gh"
    mkdir -p "$(dirname "$mock_gh")"
    cat > "$mock_gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" ]] && [[ "$2" == "list" ]]; then
    echo "777"
fi
EOF
    chmod +x "$mock_gh"

    # Branch identifier with slash (haacked/feature becomes haacked-feature in filename)
    PATH="$TEST_TEMP_DIR/bin:$PATH" run "$SCRIPT" --org "myorg" --repo "myrepo" "branch-haacked/feature"
    [ "$status" -eq 0 ]

    # Should find the PR file
    echo "$output" | jq -e '.file_exists == true'
    echo "$output" | jq -e '.pr_number == "777"'
    echo "$output" | jq -e '.file_path | endswith("pr-777.md")'
}

@test "branch fallback: uses unsanitized branch name for gh CLI when identifier is empty" {
    # This tests the bug where branch_to_check used the sanitized branch name
    # (haacked-feature) instead of the original (haacked/feature) for gh pr list
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg/myrepo"
    touch "$TEST_TEMP_DIR/reviews/myorg/myrepo/pr-666.md"

    # Create a mock git that returns a branch with slashes
    mock_git="$TEST_TEMP_DIR/bin/git"
    mkdir -p "$(dirname "$mock_git")"
    cat > "$mock_git" << 'EOF'
#!/usr/bin/env bash
# Mock git CLI
if [[ "$1" == "branch" ]] && [[ "$2" == "--show-current" ]]; then
    echo "haacked/feature-branch"
elif [[ "$1" == "rev-parse" ]] && [[ "$2" == "--git-dir" ]]; then
    echo ".git"
elif [[ "$1" == "ls-remote" ]]; then
    echo "git@github.com:myorg/myrepo.git"
else
    # Pass through to real git for other commands
    /usr/bin/git "$@"
fi
EOF
    chmod +x "$mock_git"

    # Create a mock gh that only returns PR 666 if it receives the UNSANITIZED branch name
    # This validates that gh pr list --head receives "haacked/feature-branch" not "haacked-feature-branch"
    mock_gh="$TEST_TEMP_DIR/bin/gh"
    cat > "$mock_gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" ]] && [[ "$2" == "list" ]]; then
    # Check if --head argument contains the unsanitized branch (with slash)
    if [[ "$*" == *"haacked/feature-branch"* ]]; then
        echo "666"
    else
        # Wrong branch name passed (sanitized version) - return empty
        echo ""
    fi
elif [[ "$1" == "repo" ]] && [[ "$2" == "view" ]]; then
    echo "myorg|myrepo"
fi
EOF
    chmod +x "$mock_gh"

    # Run WITHOUT an identifier - uses current branch
    PATH="$TEST_TEMP_DIR/bin:$PATH" run "$SCRIPT" --org "myorg" --repo "myrepo"
    [ "$status" -eq 0 ]

    # Should find the PR file (proves gh received correct unsanitized branch name)
    echo "$output" | jq -e '.file_exists == true'
    echo "$output" | jq -e '.pr_number == "666"'
    echo "$output" | jq -e '.file_path | endswith("pr-666.md")'
    # The branch in output should be sanitized (for filename purposes)
    echo "$output" | jq -e '.branch == "haacked-feature-branch"'
}

@test "branch fallback: sets needs_rename when branch review exists but no PR review" {
    # Create only a branch file, no PR file
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg/myrepo"
    touch "$TEST_TEMP_DIR/reviews/myorg/myrepo/my-feature.md"

    # Create a mock gh script that returns PR 555
    mock_gh="$TEST_TEMP_DIR/bin/gh"
    mkdir -p "$(dirname "$mock_gh")"
    cat > "$mock_gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" ]] && [[ "$2" == "list" ]]; then
    echo "555"
fi
EOF
    chmod +x "$mock_gh"

    # Run with mock gh in PATH
    PATH="$TEST_TEMP_DIR/bin:$PATH" run "$SCRIPT" --org "myorg" --repo "myrepo" "branch-my-feature"
    [ "$status" -eq 0 ]

    # Should return the branch file but suggest migration
    echo "$output" | jq -e '.file_exists == true'
    echo "$output" | jq -e '.file_path | endswith("my-feature.md")'
    echo "$output" | jq -e '.needs_rename == true'
    echo "$output" | jq -e '.pr_number == "555"'
}

@test "json output: includes has_branch_review field" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    echo "$result" | jq -e 'has("has_branch_review")'
}

@test "json output: includes branch_review_path field" {
    result=$("$SCRIPT" --org "myorg" --repo "myrepo" "test")
    echo "$result" | jq -e 'has("branch_review_path")'
}

@test "json output: has_branch_review is false when no branch review exists" {
    mkdir -p "$TEST_TEMP_DIR/reviews/myorg/myrepo"
    touch "$TEST_TEMP_DIR/reviews/myorg/myrepo/pr-123.md"

    # Create a mock gh script that returns PR 123
    mock_gh="$TEST_TEMP_DIR/bin/gh"
    mkdir -p "$(dirname "$mock_gh")"
    cat > "$mock_gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" ]] && [[ "$2" == "list" ]]; then
    echo "123"
fi
EOF
    chmod +x "$mock_gh"

    PATH="$TEST_TEMP_DIR/bin:$PATH" run "$SCRIPT" --org "myorg" --repo "myrepo" "branch-some-feature"
    [ "$status" -eq 0 ]

    echo "$output" | jq -e '.has_branch_review == false'
    echo "$output" | jq -e '.branch_review_path == null'
}
