#!/usr/bin/env bats
# Tests for diff-position-mapper.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/diff-position-mapper.sh"
    FIXTURES_DIR="$PROJECT_ROOT/tests/fixtures/diffs"
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "diff-position-mapper: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "diff-position-mapper: uses set -euo pipefail" {
    run bash -c "head -30 '$SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "diff-position-mapper: has build_position_map function" {
    run bash -c "grep -q '^build_position_map()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "diff-position-mapper: has lookup_position function" {
    run bash -c "grep -q '^lookup_position()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "diff-position-mapper: has main function" {
    run bash -c "grep -q '^main()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Input validation tests
# =============================================================================

@test "diff-position-mapper: rejects invalid JSON input" {
    run bash -c "echo 'not json' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid JSON"* ]]
}

@test "diff-position-mapper: rejects missing diff field" {
    run bash -c "echo '{\"targets\": []}' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No diff provided"* ]]
}

@test "diff-position-mapper: accepts empty targets array" {
    local input='{"diff": "diff --git a/test.txt b/test.txt", "targets": []}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mappings": []'* ]]
}

# =============================================================================
# build_position_map tests
# =============================================================================

@test "diff-position-mapper: maps single file diff correctly" {
    local input
    input=$(cat "$FIXTURES_DIR/simple-single-file.diff" | jq -Rs '{diff: ., targets: [{path: "src/utils.ts", line: 1}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # Line 1 in a new file should map to line 1
    local line
    line=$(echo "$output" | jq -r '.mappings[0].line')
    [ "$line" = "1" ]
}

@test "diff-position-mapper: maps multiple lines in same file" {
    local diff
    diff=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "src/utils.ts", line: 1}, {path: "src/utils.ts", line: 5}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # Should have 2 mappings
    local count
    count=$(echo "$output" | jq '.mappings | length')
    [ "$count" -eq 2 ]
}

@test "diff-position-mapper: includes side field in mapping" {
    local diff
    diff=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "src/utils.ts", line: 1}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # Added lines should have side "RIGHT"
    local side
    side=$(echo "$output" | jq -r '.mappings[0].side')
    [ "$side" = "RIGHT" ]
}

# =============================================================================
# lookup_position tests
# =============================================================================

@test "diff-position-mapper: returns error for file not in diff" {
    local diff
    diff=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "nonexistent.ts", line: 1}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    local error
    error=$(echo "$output" | jq -r '.mappings[0].error')
    [ "$error" = "file not in diff" ]
}

@test "diff-position-mapper: returns error for line not in diff" {
    local diff
    diff=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "src/utils.ts", line: 999}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    local error
    error=$(echo "$output" | jq -r '.mappings[0].error')
    [ "$error" = "line not in diff" ]
}

@test "diff-position-mapper: returns error for unmapped lines" {
    local diff
    diff=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "src/utils.ts", line: 999}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    local error
    error=$(echo "$output" | jq -r '.mappings[0].error')
    [ "$error" = "line not in diff" ]
}

# =============================================================================
# Multi-file diff tests
# =============================================================================

@test "diff-position-mapper: handles multi-file diff" {
    local diff
    diff=$(cat "$FIXTURES_DIR/python-flask.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "api/app.py", line: 1}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # Should successfully map the first line (no error means it was mapped)
    local error
    error=$(echo "$output" | jq -r '.mappings[0].error // "none"')
    [ "$error" = "none" ]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "diff-position-mapper: handles empty diff content gracefully" {
    local input='{"diff": "", "targets": []}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
}

@test "diff-position-mapper: preserves path in output" {
    local diff
    diff=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "src/utils.ts", line: 1}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    local path
    path=$(echo "$output" | jq -r '.mappings[0].path')
    [ "$path" = "src/utils.ts" ]
}

@test "diff-position-mapper: preserves line in output" {
    local diff
    diff=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "src/utils.ts", line: 5}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    local line
    line=$(echo "$output" | jq '.mappings[0].line')
    [ "$line" = "5" ]
}

@test "diff-position-mapper: outputs valid JSON" {
    local diff
    diff=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "src/utils.ts", line: 1}]}')

    run bash -c "echo '$input' | '$SCRIPT' | jq empty"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Integration tests with realistic diffs
# =============================================================================

@test "diff-position-mapper: maps typescript-react diff" {
    local diff
    diff=$(cat "$FIXTURES_DIR/typescript-react.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: []}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "diff-position-mapper: maps rust-web diff" {
    local diff
    diff=$(cat "$FIXTURES_DIR/rust-web.diff")
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: []}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
}
