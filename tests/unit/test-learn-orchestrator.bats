#!/usr/bin/env bats
# Tests for learn-orchestrator.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary directory for testing
    TEST_DIR=$(mktemp -d)
    export TEST_DIR

    # Create a mock git repository for testing (suppress output)
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init > /dev/null 2>&1
    git config commit.gpgsign false
    git config user.email "test@example.com"
    git config user.name "Test User"
    git remote add origin "https://github.com/testorg/testrepo.git"

    # Create initial commit (suppress output)
    echo "initial" > file.txt
    git add file.txt
    git commit -m "Initial commit" > /dev/null 2>&1

    # Set up mock learnings directory
    LEARNINGS_DIR="$TEST_DIR/learnings"
    mkdir -p "$LEARNINGS_DIR"
}

teardown() {
    # Clean up test directories
    rm -rf "$TEST_DIR"
    rm -rf "$TEST_REPO"
}

# =============================================================================
# Basic functionality tests
# =============================================================================

@test "learn-orchestrator.sh: exists and is executable" {
    [ -x "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" ]
}

@test "learn-orchestrator.sh: requires submode argument" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "error"' > /dev/null
    echo "$output" | jq -e '.error | contains("Submode required")' > /dev/null
}

@test "learn-orchestrator.sh: rejects unknown submode" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "invalid"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "error"' > /dev/null
    echo "$output" | jq -e '.error | contains("Unknown submode")' > /dev/null
}

@test "learn-orchestrator.sh: outputs valid JSON on error" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "error"' > /dev/null
}

# =============================================================================
# Single submode tests
# =============================================================================

@test "learn-orchestrator.sh: single requires PR number" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "single"
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "error"' > /dev/null
    echo "$output" | jq -e '.error | contains("PR number required")' > /dev/null
}

@test "learn-orchestrator.sh: single accepts PR number" {
    # This will fail because there's no review file, but it should parse correctly
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "single" "123" --org testorg --repo testrepo
    # Should fail with meaningful error about missing review file
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "error"' > /dev/null
}

@test "learn-orchestrator.sh: single accepts --org and --repo flags" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "single" "456" --org myorg --repo myrepo
    # Should fail with error (no review file) but parse arguments correctly
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "error"' > /dev/null
}

# =============================================================================
# Batch submode tests
# =============================================================================

@test "learn-orchestrator.sh: batch runs without arguments" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "batch"
    # Should succeed with empty results (no reviews to analyze)
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ready"' > /dev/null
    echo "$output" | jq -e '.submode == "batch"' > /dev/null
}

@test "learn-orchestrator.sh: batch accepts --limit flag" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "batch" --limit 10
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ready"' > /dev/null
}

@test "learn-orchestrator.sh: batch returns count field" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "batch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.count >= 0' > /dev/null
}

@test "learn-orchestrator.sh: batch returns prs array" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "batch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.prs | type == "array"' > /dev/null
}

# =============================================================================
# Apply submode tests
# =============================================================================

@test "learn-orchestrator.sh: apply runs without arguments" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "apply"
    # Should succeed with empty proposals (no learnings)
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ready"' > /dev/null
    echo "$output" | jq -e '.submode == "apply"' > /dev/null
}

@test "learn-orchestrator.sh: apply accepts --threshold flag" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "apply" --threshold 5
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ready"' > /dev/null
}

@test "learn-orchestrator.sh: apply returns actionable count" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "apply"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.actionable >= 0' > /dev/null
}

@test "learn-orchestrator.sh: apply returns proposals object" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "apply"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals | type == "object"' > /dev/null
}

# =============================================================================
# JSON output structure tests
# =============================================================================

@test "learn-orchestrator.sh: all submodes return status field" {
    # Batch mode (should succeed)
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "batch"
    echo "$output" | jq -e '.status' > /dev/null

    # Apply mode (should succeed)
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "apply"
    echo "$output" | jq -e '.status' > /dev/null
}

@test "learn-orchestrator.sh: all submodes return submode field" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "batch"
    echo "$output" | jq -e '.submode == "batch"' > /dev/null

    run "$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh" "apply"
    echo "$output" | jq -e '.submode == "apply"' > /dev/null
}

@test "learn-orchestrator.sh: can be sourced without executing main" {
    run bash -c "source '$PROJECT_ROOT/skills/review-code/scripts/learn-orchestrator.sh' && echo 'sourced ok'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced ok"* ]]
}
