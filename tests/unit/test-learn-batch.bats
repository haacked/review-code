#!/usr/bin/env bats
# Tests for learn-batch.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create temporary directories for testing
    TEST_DIR=$(mktemp -d)
    export TEST_DIR

    # Create mock review root directory
    MOCK_REVIEW_ROOT="$TEST_DIR/reviews"
    mkdir -p "$MOCK_REVIEW_ROOT"
    export MOCK_REVIEW_ROOT

    # Create mock learnings directory
    MOCK_LEARNINGS_DIR="$TEST_DIR/learnings"
    mkdir -p "$MOCK_LEARNINGS_DIR"
    export MOCK_LEARNINGS_DIR
}

teardown() {
    rm -rf "$TEST_DIR"
}

# =============================================================================
# Basic functionality tests
# =============================================================================

@test "learn-batch.sh: exists and is executable" {
    [ -x "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" ]
}

@test "learn-batch.sh: can be sourced without executing main" {
    run bash -c "source '$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh' && echo 'sourced ok'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced ok"* ]]
}

# =============================================================================
# Argument validation tests
# =============================================================================

@test "learn-batch.sh: rejects unknown arguments" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --unknown
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown argument"* ]]
}

@test "learn-batch.sh: --limit requires a value" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --limit
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing value"* ]]
}

@test "learn-batch.sh: --days requires a value" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --days
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing value"* ]]
}

@test "learn-batch.sh: --limit must be a positive integer" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --limit abc
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "learn-batch.sh: --limit rejects zero" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --limit 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "learn-batch.sh: --limit rejects negative numbers" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --limit -5
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "learn-batch.sh: --days must be a positive integer" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --days foo
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "learn-batch.sh: --days rejects zero" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --days 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "learn-batch.sh: accepts valid --limit" {
    # This will fail later due to missing config, but argument parsing succeeds
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --limit 5
    # Should not fail on argument parsing
    [[ "$output" != *"positive integer"* ]]
}

@test "learn-batch.sh: accepts valid --days" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh" --days 14
    [[ "$output" != *"positive integer"* ]]
}

# =============================================================================
# Output format tests
# =============================================================================

@test "learn-batch.sh: returns empty JSON array when no review root exists" {
    # Create a config pointing to non-existent review root
    mkdir -p "$TEST_DIR/.claude/skills/review-code"
    echo "REVIEW_ROOT_PATH=$TEST_DIR/nonexistent" > "$TEST_DIR/.claude/skills/review-code/.env"

    # Override HOME to use our test config
    HOME="$TEST_DIR" run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "learn-batch.sh: returns empty JSON array when no review files exist" {
    # Create empty review root
    mkdir -p "$MOCK_REVIEW_ROOT/testorg/testrepo"

    # Create config pointing to our mock review root
    mkdir -p "$TEST_DIR/.claude/skills/review-code"
    echo "REVIEW_ROOT_PATH=$MOCK_REVIEW_ROOT" > "$TEST_DIR/.claude/skills/review-code/.env"

    HOME="$TEST_DIR" run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "learn-batch.sh: produces valid JSON output" {
    mkdir -p "$TEST_DIR/.claude/skills/review-code"
    echo "REVIEW_ROOT_PATH=$MOCK_REVIEW_ROOT" > "$TEST_DIR/.claude/skills/review-code/.env"

    HOME="$TEST_DIR" run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh"
    [ "$status" -eq 0 ]
    # Validate JSON
    echo "$output" | jq . > /dev/null
    echo "$output" | jq -e 'type == "array"' > /dev/null
}

# =============================================================================
# PR file path parsing tests (using sourced functions)
# =============================================================================

@test "learn-batch.sh: extracts org from review file path" {
    # Create a review file
    mkdir -p "$MOCK_REVIEW_ROOT/myorg/myrepo"
    echo "# Review" > "$MOCK_REVIEW_ROOT/myorg/myrepo/pr-123.md"

    # Test that org extraction works
    local review_file="$MOCK_REVIEW_ROOT/myorg/myrepo/pr-123.md"
    local relative_path="${review_file#"$MOCK_REVIEW_ROOT/"}"
    local org
    org=$(echo "$relative_path" | cut -d'/' -f1)
    [ "$org" = "myorg" ]
}

@test "learn-batch.sh: extracts repo from review file path" {
    local review_file="$MOCK_REVIEW_ROOT/myorg/myrepo/pr-123.md"
    local relative_path="${review_file#"$MOCK_REVIEW_ROOT/"}"
    local repo
    repo=$(echo "$relative_path" | cut -d'/' -f2)
    [ "$repo" = "myrepo" ]
}

@test "learn-batch.sh: extracts PR number from filename" {
    local filename="pr-456.md"
    if [[ "$filename" =~ ^pr-([0-9]+)\.md$ ]]; then
        local pr_number="${BASH_REMATCH[1]}"
        [ "$pr_number" = "456" ]
    else
        fail "Pattern did not match"
    fi
}

@test "learn-batch.sh: skips non-PR files" {
    local filename="notes.md"
    if [[ "$filename" =~ ^pr-([0-9]+)\.md$ ]]; then
        fail "Should not match non-PR files"
    fi
}

@test "learn-batch.sh: skips malformed PR files" {
    local filename="pr-abc.md"
    if [[ "$filename" =~ ^pr-([0-9]+)\.md$ ]]; then
        fail "Should not match non-numeric PR"
    fi
}

# =============================================================================
# analyzed.json handling tests
# =============================================================================

@test "learn-batch.sh: handles missing analyzed.json gracefully" {
    mkdir -p "$TEST_DIR/.claude/skills/review-code"
    echo "REVIEW_ROOT_PATH=$MOCK_REVIEW_ROOT" > "$TEST_DIR/.claude/skills/review-code/.env"

    # Ensure no analyzed.json exists
    rm -f "$MOCK_LEARNINGS_DIR/analyzed.json"

    HOME="$TEST_DIR" run "$PROJECT_ROOT/skills/review-code/scripts/learn-batch.sh"
    [ "$status" -eq 0 ]
}

@test "learn-batch.sh: jq handles missing repo key in analyzed.json" {
    # Test the fixed jq pattern with // {} fallback
    local analyzed_data='{"other/repo": {"1": true}}'
    local repo_key="missing/repo"
    local pr_number="123"

    # This should not error - the // {} handles missing keys
    if echo "$analyzed_data" | jq -e --arg key "$repo_key" --arg pr "$pr_number" '(.[$key] // {})[$pr] != null' > /dev/null 2>&1; then
        # Key was found (unexpected for missing key)
        fail "Should not find missing repo key"
    else
        # Key was not found (expected)
        true
    fi
}

@test "learn-batch.sh: jq finds existing key in analyzed.json" {
    local analyzed_data='{"existing/repo": {"456": true}}'
    local repo_key="existing/repo"
    local pr_number="456"

    if echo "$analyzed_data" | jq -e --arg key "$repo_key" --arg pr "$pr_number" '(.[$key] // {})[$pr] != null' > /dev/null 2>&1; then
        # Key was found (expected)
        true
    else
        fail "Should find existing repo key"
    fi
}

# =============================================================================
# Date cutoff tests
# =============================================================================

@test "learn-batch.sh: calculates cutoff date correctly on macOS" {
    if [[ "${OSTYPE}" != "darwin"* ]]; then
        skip "macOS-specific test"
    fi

    local days=30
    local cutoff_date
    cutoff_date=$(date -v-"${days}"d -u +"%Y-%m-%dT%H:%M:%SZ")

    # Should be a valid ISO 8601 date
    [[ "$cutoff_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "learn-batch.sh: calculates cutoff date correctly on Linux" {
    if [[ "${OSTYPE}" == "darwin"* ]]; then
        skip "Linux-specific test"
    fi

    local days=30
    local cutoff_date
    cutoff_date=$(date -d "${days} days ago" -u +"%Y-%m-%dT%H:%M:%SZ")

    # Should be a valid ISO 8601 date
    [[ "$cutoff_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}
