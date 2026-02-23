#!/usr/bin/env bats

# Tests for inject-handler.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/inject-handler.sh"
    HANDLER_DIR="$PROJECT_ROOT/skills/review-code/handlers"

    # Create a temporary git repository so parse-review-arg.sh works
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init -q -b main
    git config commit.gpgsign false
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"
    git remote add origin "https://github.com/testorg/testrepo.git" 2>/dev/null || true
}

teardown() {
    rm -rf "$TEST_REPO"
}

# =============================================================================
# Learn mode tests
# =============================================================================

@test "inject-handler: outputs learn.md content for 'learn' argument" {
    run "$SCRIPT" learn
    [ "$status" -eq 0 ]

    # Verify it contains learn handler content
    expected_start="$(head -1 "$HANDLER_DIR/learn.md")"
    [[ "$output" == *"$expected_start"* ]]
}

@test "inject-handler: outputs learn.md content for 'learn 123' argument" {
    run "$SCRIPT" learn 123
    [ "$status" -eq 0 ]

    expected_start="$(head -1 "$HANDLER_DIR/learn.md")"
    [[ "$output" == *"$expected_start"* ]]
}

# =============================================================================
# Find mode tests
# =============================================================================

@test "inject-handler: outputs find.md content for 'find' argument" {
    run "$SCRIPT" find
    [ "$status" -eq 0 ]

    expected_start="$(head -1 "$HANDLER_DIR/find.md")"
    [[ "$output" == *"$expected_start"* ]]
}

@test "inject-handler: outputs find.md content for 'find 123' argument" {
    run "$SCRIPT" find 123
    [ "$status" -eq 0 ]

    expected_start="$(head -1 "$HANDLER_DIR/find.md")"
    [[ "$output" == *"$expected_start"* ]]
}

# =============================================================================
# Review mode tests (default handler)
# =============================================================================

@test "inject-handler: outputs review.md content for area keyword" {
    run "$SCRIPT" security
    [ "$status" -eq 0 ]

    expected_start="$(head -1 "$HANDLER_DIR/review.md")"
    [[ "$output" == *"$expected_start"* ]]
}

@test "inject-handler: outputs review.md content for PR number" {
    run "$SCRIPT" 123
    [ "$status" -eq 0 ]

    expected_start="$(head -1 "$HANDLER_DIR/review.md")"
    [[ "$output" == *"$expected_start"* ]]
}

@test "inject-handler: outputs review.md content for branch argument" {
    # Create a feature branch so parse-review-arg detects it as a branch
    cd "$TEST_REPO"
    git checkout -q -b feature-branch
    echo "change" > file.txt
    git add file.txt
    git commit -q -m "Feature commit"
    git checkout -q main

    run "$SCRIPT" feature-branch
    [ "$status" -eq 0 ]

    expected_start="$(head -1 "$HANDLER_DIR/review.md")"
    [[ "$output" == *"$expected_start"* ]]
}

# =============================================================================
# Error handling tests
# =============================================================================

@test "inject-handler: outputs minimal message for parse error instead of loading review handler" {
    # Pass an argument that triggers a parse error (no git remote context)
    # by running from a non-git directory
    cd /tmp
    run "$SCRIPT" "not-a-valid-arg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No handler loaded"* ]]
    [[ "$output" != *"$(head -1 "$HANDLER_DIR/review.md")"* ]]
}

@test "inject-handler: handles missing handler file gracefully" {
    # Temporarily rename the review handler to simulate missing file.
    # Use a trap to guarantee restoration even if an assertion fails.
    mv "$HANDLER_DIR/review.md" "$HANDLER_DIR/review.md.bak"
    trap 'mv "$HANDLER_DIR/review.md.bak" "$HANDLER_DIR/review.md" 2>/dev/null || true' RETURN

    run "$SCRIPT" security
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR"* ]]
}
