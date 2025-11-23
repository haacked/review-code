#!/usr/bin/env bats

# Tests for conditional JSON building (refactored in PR #4)
# This file tests that build_review_data() and build_summary() correctly
# handle optional PR context fields

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for tests that need consistent git state
    # This ensures tests work both locally and in CI (where we're in detached HEAD)
    TEST_GIT_DIR="$(mktemp -d)"
}

teardown() {
    # Cleanup temporary git directory
    if [ -n "$TEST_GIT_DIR" ] && [ -d "$TEST_GIT_DIR" ]; then
        rm -rf "$TEST_GIT_DIR"
    fi
}

# Helper: Setup a minimal git repository in TEST_GIT_DIR
setup_test_git_repo() {
    cd "$TEST_GIT_DIR"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial commit on main branch
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"

    # Ensure we're on main branch
    git checkout -q -b main 2>/dev/null || git checkout -q main

    # Set up a fake remote origin (needed for some git commands to work)
    # Use a fake GitHub URL to prevent git commands from failing
    git remote add origin https://github.com/test/test.git 2>/dev/null || true
}

# =============================================================================
# build_review_data() Conditional PR Field Tests
# =============================================================================

@test "review-orchestrator: outputs valid JSON without PR context" {
    # Use a temporary git repo so CI detached HEAD doesn't interfere
    setup_test_git_repo
    git checkout -b feature-no-pr 2>/dev/null || true

    # Stay on feature branch with no PR context
    run bash -c "cd '$TEST_GIT_DIR' && '$PROJECT_ROOT/lib/review-orchestrator.sh' '' 2>/dev/null"
    [ "$status" -eq 0 ]

    # Output should be valid JSON
    echo "$output" | jq . >/dev/null
}

@test "review-orchestrator: JSON has status field" {
    setup_test_git_repo
    git checkout -b feature-no-pr 2>/dev/null || true

    run bash -c "cd '$TEST_GIT_DIR' && '$PROJECT_ROOT/lib/review-orchestrator.sh' '' 2>/dev/null"
    [ "$status" -eq 0 ]

    # Should have status field
    status_value=$(echo "$output" | jq -r '.status')
    [ -n "$status_value" ]
}

@test "review-orchestrator: handles branch without PR gracefully" {
    setup_test_git_repo

    # Create a test branch
    git checkout -b test-no-pr-$$ 2>/dev/null || true
    git commit --allow-empty -m "Test" 2>/dev/null || true

    # Get review data (will be prompt status due to uncommitted state)
    run bash -c "cd '$TEST_GIT_DIR' && '$PROJECT_ROOT/lib/review-orchestrator.sh' '' 2>/dev/null"
    [ "$status" -eq 0 ]

    # Should be valid JSON
    echo "$output" | jq . >/dev/null

    # Cleanup
    git checkout - >/dev/null 2>&1 || true
    git branch -D test-no-pr-$$ >/dev/null 2>&1 || true
}

# =============================================================================
# JSON Structure Tests
# =============================================================================

@test "git-context: produces valid JSON" {
    run bash -c "cd '$PROJECT_ROOT' && ./lib/git-context.sh"
    [ "$status" -eq 0 ]

    # Validate JSON structure
    echo "$output" | jq . >/dev/null
}

@test "git-context: includes required fields" {
    run bash -c "cd '$PROJECT_ROOT' && ./lib/git-context.sh"
    [ "$status" -eq 0 ]

    # Check for required fields
    echo "$output" | jq -e '.org' >/dev/null
    echo "$output" | jq -e '.repo' >/dev/null
    echo "$output" | jq -e '.branch' >/dev/null
    echo "$output" | jq -e '.commit' >/dev/null
}

@test "git-context: org and repo are not empty" {
    run bash -c "cd '$PROJECT_ROOT' && ./lib/git-context.sh"
    [ "$status" -eq 0 ]

    org=$(echo "$output" | jq -r '.org')
    repo=$(echo "$output" | jq -r '.repo')

    [ -n "$org" ]
    [ -n "$repo" ]
}

# =============================================================================
# PR Context Conditional Tests
# =============================================================================

@test "orchestrator with PR number: attempts to fetch PR context" {
    # Setup a test git repo with known state (not detached HEAD)
    setup_test_git_repo

    # Test that providing a PR number triggers PR context fetching
    # This may fail if gh not available or PR doesn't exist, but shouldn't crash
    run bash -c "cd '$TEST_GIT_DIR' && '$PROJECT_ROOT/lib/review-orchestrator.sh' 'https://github.com/haacked/review-code/pull/1' 2>/dev/null"

    # Should exit with 0 or gracefully handle missing PR
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # If successful, output should be valid JSON
    if [ "$status" -eq 0 ]; then
        echo "$output" | jq . >/dev/null
    fi
}

# =============================================================================
# Error Handling Tests
# =============================================================================

@test "orchestrator: handles invalid input gracefully" {
    run bash -c "cd '$PROJECT_ROOT' && ./lib/review-orchestrator.sh 'invalid-ref-xyz-123' 2>/dev/null"

    # Should fail gracefully with error status or error JSON
    if [ "$status" -eq 0 ]; then
        # If it returns 0, should be valid JSON with error status
        echo "$output" | jq -e '.status == "error"' >/dev/null
    fi
}

@test "orchestrator: empty argument doesn't crash" {
    setup_test_git_repo
    git checkout -b feature-no-pr 2>/dev/null || true

    run bash -c "cd '$TEST_GIT_DIR' && '$PROJECT_ROOT/lib/review-orchestrator.sh' '' 2>/dev/null"
    [ "$status" -eq 0 ]

    # Should return valid JSON
    echo "$output" | jq . >/dev/null
}

# =============================================================================
# Regression Tests (ensure refactoring didn't break anything)
# =============================================================================

@test "regression: orchestrator still handles commit SHA" {
    # Get current HEAD commit
    commit=$(git rev-parse HEAD)

    run bash -c "cd '$PROJECT_ROOT' && ./lib/review-orchestrator.sh '$commit' 2>/dev/null"

    # Should succeed or return valid error JSON
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    if [ "$status" -eq 0 ]; then
        echo "$output" | jq . >/dev/null
        # Should have ready or appropriate status
        echo "$output" | jq -e '.status' >/dev/null
    fi
}

@test "regression: orchestrator still handles branch name" {
    # Setup a test git repo with known state (not detached HEAD)
    setup_test_git_repo

    # Create a feature branch so "main" is not the current branch
    git checkout -q -b feature-branch

    # Test with main branch (from temp repo)
    run bash -c "cd '$TEST_GIT_DIR' && '$PROJECT_ROOT/lib/review-orchestrator.sh' 'main' 2>/dev/null"

    # Should succeed with valid JSON
    [ "$status" -eq 0 ]
    echo "$output" | jq . >/dev/null
}

# =============================================================================
# gh CLI Integration Tests
# =============================================================================

@test "get_git_org_repo: works with gh CLI available" {
    if ! command -v gh >/dev/null 2>&1; then
        skip "gh CLI not available"
    fi

    run bash -c "cd '$PROJECT_ROOT' && source lib/helpers/git-helpers.sh && get_git_org_repo"
    [ "$status" -eq 0 ]

    # Should return org|repo format
    [[ "$output" == *"|"* ]]
}

@test "get_git_org_repo: works without gh CLI" {
    # Test fallback to git URL parsing
    run bash -c "cd '$PROJECT_ROOT' && PATH=/usr/bin:/bin source lib/helpers/git-helpers.sh && get_git_org_repo"
    [ "$status" -eq 0 ]

    # Should return org|repo format (or unknown|unknown)
    [[ "$output" == *"|"* ]]
}

@test "get_git_org_repo: returns lowercase org" {
    run bash -c "cd '$PROJECT_ROOT' && source lib/helpers/git-helpers.sh && get_git_org_repo"
    [ "$status" -eq 0 ]

    org="${output%|*}"
    # Org should be lowercase (no uppercase letters)
    [[ ! "$org" =~ [A-Z] ]]
}

# =============================================================================
# display_summary Field Tests
# =============================================================================

@test "orchestrator: includes display_summary field in ready status" {
    # Use a range to ensure ready status (not ambiguous)
    run bash -c "cd '$PROJECT_ROOT' && ./lib/review-orchestrator.sh 'HEAD~1..HEAD' 2>/dev/null"
    [ "$status" -eq 0 ]

    # Should have display_summary field
    echo "$output" | jq -e '.display_summary' >/dev/null
}

@test "orchestrator: display_summary is non-empty string" {
    # Use a range to ensure ready status
    run bash -c "cd '$PROJECT_ROOT' && ./lib/review-orchestrator.sh 'HEAD~1..HEAD' 2>/dev/null"
    [ "$status" -eq 0 ]

    display_summary=$(echo "$output" | jq -r '.display_summary')
    [ -n "$display_summary" ]
}

@test "orchestrator: display_summary contains 'Review Summary'" {
    # Use a range to ensure ready status
    run bash -c "cd '$PROJECT_ROOT' && ./lib/review-orchestrator.sh 'HEAD~1..HEAD' 2>/dev/null"
    [ "$status" -eq 0 ]

    display_summary=$(echo "$output" | jq -r '.display_summary')
    [[ "$display_summary" == *"Review Summary"* ]]
}

@test "orchestrator: display_summary includes file path" {
    # Use a range to ensure ready status
    run bash -c "cd '$PROJECT_ROOT' && ./lib/review-orchestrator.sh 'HEAD~1..HEAD' 2>/dev/null"
    [ "$status" -eq 0 ]

    # Extract both display_summary and file_path
    display_summary=$(echo "$output" | jq -r '.display_summary')
    file_path=$(echo "$output" | jq -r '.file_info.file_path')

    # display_summary should contain the file path
    [[ "$display_summary" == *"$file_path"* ]]
}

@test "orchestrator: display_summary includes repository info" {
    # Use a range to ensure ready status
    run bash -c "cd '$PROJECT_ROOT' && ./lib/review-orchestrator.sh 'HEAD~1..HEAD' 2>/dev/null"
    [ "$status" -eq 0 ]

    display_summary=$(echo "$output" | jq -r '.display_summary')

    # Should contain repository information
    [[ "$display_summary" == *"Repository:"* ]]
}

@test "orchestrator: display_summary includes stats" {
    # Use a range to ensure ready status
    run bash -c "cd '$PROJECT_ROOT' && ./lib/review-orchestrator.sh 'HEAD~1..HEAD' 2>/dev/null"
    [ "$status" -eq 0 ]

    display_summary=$(echo "$output" | jq -r '.display_summary')

    # Should contain change statistics
    [[ "$display_summary" == *"Changes:"* ]]
    [[ "$display_summary" == *"Files:"* ]]
}
