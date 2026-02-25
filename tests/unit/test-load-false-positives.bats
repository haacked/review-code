#!/usr/bin/env bats
# Tests for load-false-positives.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create temp learnings directory for testing
    TEST_LEARNINGS_DIR=$(mktemp -d)
    export LEARNINGS_PATH="$TEST_LEARNINGS_DIR"
}

teardown() {
    rm -rf "$TEST_LEARNINGS_DIR"
}

# =============================================================================
# Empty/missing file tests
# =============================================================================

@test "load-false-positives.sh: returns empty when no index file exists" {
    run "$PROJECT_ROOT/skills/review-code/scripts/load-false-positives.sh"
    [ "$status" -eq 0 ]
    content=$(echo "$output" | jq -r '.content')
    count=$(echo "$output" | jq -r '.count')
    [ -z "$content" ]
    [ "$count" -eq 0 ]
}

@test "load-false-positives.sh: returns empty when index file is empty" {
    touch "$TEST_LEARNINGS_DIR/index.jsonl"
    run "$PROJECT_ROOT/skills/review-code/scripts/load-false-positives.sh"
    [ "$status" -eq 0 ]
    content=$(echo "$output" | jq -r '.content')
    count=$(echo "$output" | jq -r '.count')
    [ -z "$content" ]
    [ "$count" -eq 0 ]
}

# =============================================================================
# Filtering tests
# =============================================================================

@test "load-false-positives.sh: filters for false_positive type only" {
    cat > "$TEST_LEARNINGS_DIR/index.jsonl" << 'JSONL'
{"type":"false_positive","agent":"security","finding":{"file":"auth.py","description":"SQL injection false alarm"},"context":{"language":"python"},"pr_number":100}
{"type":"missed_pattern","agent":"testing","finding":{"file":"test.py","description":"Missing edge case"},"context":{"language":"python"},"pr_number":101}
{"type":"valid_catch","agent":"correctness","finding":{"file":"api.py","description":"Bug found"},"context":{"language":"python"},"pr_number":102}
JSONL

    run "$PROJECT_ROOT/skills/review-code/scripts/load-false-positives.sh"
    [ "$status" -eq 0 ]
    count=$(echo "$output" | jq -r '.count')
    [ "$count" -eq 1 ]
    content=$(echo "$output" | jq -r '.content')
    [[ "$content" == *"SQL injection false alarm"* ]]
    [[ "$content" != *"Missing edge case"* ]]
    [[ "$content" != *"Bug found"* ]]
}

@test "load-false-positives.sh: returns empty when no false positives exist" {
    cat > "$TEST_LEARNINGS_DIR/index.jsonl" << 'JSONL'
{"type":"missed_pattern","agent":"testing","finding":{"file":"test.py","description":"Missing edge case"},"context":{"language":"python"},"pr_number":101}
{"type":"valid_catch","agent":"correctness","finding":{"file":"api.py","description":"Bug found"},"context":{"language":"python"},"pr_number":102}
JSONL

    run "$PROJECT_ROOT/skills/review-code/scripts/load-false-positives.sh"
    [ "$status" -eq 0 ]
    content=$(echo "$output" | jq -r '.content')
    count=$(echo "$output" | jq -r '.count')
    [ -z "$content" ]
    [ "$count" -eq 0 ]
}

# =============================================================================
# Grouping tests
# =============================================================================

@test "load-false-positives.sh: groups by agent" {
    cat > "$TEST_LEARNINGS_DIR/index.jsonl" << 'JSONL'
{"type":"false_positive","agent":"security","finding":{"file":"auth.py","description":"SQL injection false alarm"},"context":{"language":"python"},"pr_number":100}
{"type":"false_positive","agent":"security","finding":{"file":"api.py","description":"XSS false alarm"},"context":{"language":"python"},"pr_number":101}
{"type":"false_positive","agent":"performance","finding":{"file":"cache.py","description":"N+1 false alarm"},"context":{"language":"python"},"pr_number":102}
JSONL

    run "$PROJECT_ROOT/skills/review-code/scripts/load-false-positives.sh"
    [ "$status" -eq 0 ]
    count=$(echo "$output" | jq -r '.count')
    [ "$count" -eq 3 ]
    content=$(echo "$output" | jq -r '.content')
    # Both agents should appear as headings
    [[ "$content" == *"### security"* ]]
    [[ "$content" == *"### performance"* ]]
}

# =============================================================================
# Output format tests
# =============================================================================

@test "load-false-positives.sh: outputs valid JSON" {
    cat > "$TEST_LEARNINGS_DIR/index.jsonl" << 'JSONL'
{"type":"false_positive","agent":"security","finding":{"file":"auth.py","description":"False alarm"},"context":{"language":"python"},"pr_number":100}
JSONL

    run "$PROJECT_ROOT/skills/review-code/scripts/load-false-positives.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
}

@test "load-false-positives.sh: includes file path and PR number in output" {
    cat > "$TEST_LEARNINGS_DIR/index.jsonl" << 'JSONL'
{"type":"false_positive","agent":"security","finding":{"file":"auth.py","description":"False alarm"},"context":{"language":"python"},"pr_number":100}
JSONL

    run "$PROJECT_ROOT/skills/review-code/scripts/load-false-positives.sh"
    [ "$status" -eq 0 ]
    content=$(echo "$output" | jq -r '.content')
    [[ "$content" == *"auth.py"* ]]
    [[ "$content" == *"PR #100"* ]]
}

@test "load-false-positives.sh: handles missing agent field gracefully" {
    cat > "$TEST_LEARNINGS_DIR/index.jsonl" << 'JSONL'
{"type":"false_positive","finding":{"file":"auth.py","description":"False alarm"},"context":{"language":"python"},"pr_number":100}
JSONL

    run "$PROJECT_ROOT/skills/review-code/scripts/load-false-positives.sh"
    [ "$status" -eq 0 ]
    count=$(echo "$output" | jq -r '.count')
    [ "$count" -eq 1 ]
    content=$(echo "$output" | jq -r '.content')
    [[ "$content" == *"### unknown"* ]]
}
