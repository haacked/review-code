#!/usr/bin/env bats
# Tests for learn-apply.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create temporary directory for testing
    TEST_DIR=$(mktemp -d)
    export TEST_DIR

    # Create mock learnings directory structure
    MOCK_LEARNINGS_DIR="$TEST_DIR/learnings"
    mkdir -p "$MOCK_LEARNINGS_DIR"
    export MOCK_LEARNINGS_DIR
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Helper to create a learning entry
create_learning() {
    local type="$1"
    local language="$2"
    local framework="${3:-null}"
    local description="${4:-Test finding}"

    if [[ "$framework" == "null" ]]; then
        cat << EOF
{"type":"$type","context":{"language":"$language"},"finding":{"description":"$description"}}
EOF
    else
        cat << EOF
{"type":"$type","context":{"language":"$language","framework":"$framework"},"finding":{"description":"$description"}}
EOF
    fi
}

# =============================================================================
# Basic functionality tests
# =============================================================================

@test "learn-apply.sh: exists and is executable" {
    [ -x "$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh" ]
}

@test "learn-apply.sh: can be sourced without executing main" {
    run bash -c "source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh' && echo 'sourced ok'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced ok"* ]]
}

# =============================================================================
# Argument validation tests
# =============================================================================

@test "learn-apply.sh: rejects unknown arguments" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh" --unknown
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown argument"* ]]
}

@test "learn-apply.sh: --threshold requires a value" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh" --threshold
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing value"* ]]
}

@test "learn-apply.sh: --threshold must be a positive integer" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh" --threshold abc
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "learn-apply.sh: --threshold rejects zero" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh" --threshold 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "learn-apply.sh: --threshold rejects negative numbers" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh" --threshold -3
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "learn-apply.sh: accepts valid --threshold" {
    # Create empty learnings file
    touch "$MOCK_LEARNINGS_DIR/index.jsonl"

    # Override SCRIPT_DIR to use mock learnings
    SCRIPT_DIR="$TEST_DIR" run bash -c "
        mkdir -p '$TEST_DIR/../learnings'
        touch '$TEST_DIR/../learnings/index.jsonl'
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 5
    "
    [[ "$output" != *"positive integer"* ]]
}

# =============================================================================
# Empty/missing learnings tests
# =============================================================================

@test "learn-apply.sh: returns empty proposals when no learnings file exists" {
    # Don't create index.jsonl
    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals | length == 0' > /dev/null
    echo "$output" | jq -e '.summary.total_learnings == 0' > /dev/null
}

@test "learn-apply.sh: returns empty proposals when learnings file is empty" {
    touch "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals | length == 0' > /dev/null
    echo "$output" | jq -e '.summary.total_learnings == 0' > /dev/null
}

# =============================================================================
# Output format tests
# =============================================================================

@test "learn-apply.sh: produces valid JSON output" {
    touch "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq . > /dev/null
    echo "$output" | jq -e 'has("proposals")' > /dev/null
    echo "$output" | jq -e 'has("summary")' > /dev/null
}

@test "learn-apply.sh: summary contains required fields" {
    touch "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.summary | has("total_learnings")' > /dev/null
    echo "$output" | jq -e '.summary | has("grouped_patterns")' > /dev/null
    echo "$output" | jq -e '.summary | has("actionable_proposals")' > /dev/null
}

# =============================================================================
# Grouping and threshold tests
# =============================================================================

@test "learn-apply.sh: groups learnings by type and language" {
    # Create 3 false_positive learnings for python (should meet default threshold)
    create_learning "false_positive" "python" "null" "FP 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "python" "null" "FP 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "python" "null" "FP 3" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main
    "
    echo '# DEBUG status=' "$status" >&3
    echo '# DEBUG output=' "$output" >&3
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.summary.grouped_patterns >= 1' > /dev/null
}

@test "learn-apply.sh: respects threshold for proposals" {
    # Create only 2 learnings (below default threshold of 3)
    create_learning "false_positive" "python" "null" "FP 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "python" "null" "FP 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main
    "
    [ "$status" -eq 0 ]
    # Should have no actionable proposals (below threshold)
    echo "$output" | jq -e '.summary.actionable_proposals == 0' > /dev/null
}

@test "learn-apply.sh: custom threshold affects proposals" {
    # Create 2 learnings
    create_learning "false_positive" "python" "null" "FP 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "python" "null" "FP 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    # Use threshold of 2
    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 2
    "
    [ "$status" -eq 0 ]
    # Should have 1 actionable proposal now
    echo "$output" | jq -e '.summary.actionable_proposals == 1' > /dev/null
}

# =============================================================================
# Learning type handling tests
# =============================================================================

@test "learn-apply.sh: handles false_positive type" {
    create_learning "false_positive" "python" "null" "FP 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "python" "null" "FP 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 2
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals[0].content | contains("False Positive")' > /dev/null
}

@test "learn-apply.sh: handles missed_pattern type" {
    create_learning "missed_pattern" "javascript" "null" "Missed 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "missed_pattern" "javascript" "null" "Missed 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 2
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals[0].content | contains("Patterns to Detect")' > /dev/null
}

@test "learn-apply.sh: handles valid_catch type" {
    create_learning "valid_catch" "go" "null" "Valid 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "valid_catch" "go" "null" "Valid 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 2
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals[0].content | contains("Validated Patterns")' > /dev/null
}

@test "learn-apply.sh: handles deferred type" {
    create_learning "deferred" "rust" "null" "Deferred 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "deferred" "rust" "null" "Deferred 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 2
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals[0].content | contains("Lower Priority")' > /dev/null
}

# =============================================================================
# Target file determination tests
# =============================================================================

@test "learn-apply.sh: targets language file when no framework" {
    create_learning "false_positive" "python" "null" "FP 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "python" "null" "FP 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 2
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals[0].target_file | contains("languages/python.md")' > /dev/null
}

@test "learn-apply.sh: targets framework file when framework specified" {
    create_learning "false_positive" "python" "django" "Django FP 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "python" "django" "Django FP 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 2
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals[0].target_file | contains("frameworks/django.md")' > /dev/null
}

# =============================================================================
# sort_by before group_by test
# =============================================================================

@test "learn-apply.sh: groups non-consecutive learnings correctly" {
    # Create learnings in non-sorted order to test sort_by before group_by
    create_learning "false_positive" "python" "null" "Python FP 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "javascript" "null" "JS FP 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "python" "null" "Python FP 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 2
    "
    [ "$status" -eq 0 ]
    # Python should have 2 learnings grouped together (meeting threshold)
    echo "$output" | jq -e '.summary.actionable_proposals == 1' > /dev/null
    echo "$output" | jq -e '.proposals[0].learnings_count == 2' > /dev/null
}

# =============================================================================
# Proposal content tests
# =============================================================================

@test "learn-apply.sh: proposal contains required fields" {
    create_learning "false_positive" "python" "null" "FP 1" >> "$MOCK_LEARNINGS_DIR/index.jsonl"
    create_learning "false_positive" "python" "null" "FP 2" >> "$MOCK_LEARNINGS_DIR/index.jsonl"

    SCRIPT_DIR="$TEST_DIR" run bash -c "
        source '$PROJECT_ROOT/skills/review-code/scripts/learn-apply.sh'
        LEARNINGS_DIR='$MOCK_LEARNINGS_DIR'
        main --threshold 2
    "
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.proposals[0] | has("target_file")' > /dev/null
    echo "$output" | jq -e '.proposals[0] | has("section")' > /dev/null
    echo "$output" | jq -e '.proposals[0] | has("content")' > /dev/null
    echo "$output" | jq -e '.proposals[0] | has("learnings_count")' > /dev/null
    echo "$output" | jq -e '.proposals[0] | has("learnings")' > /dev/null
}
