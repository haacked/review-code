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

@test "diff-position-mapper: has lookup_positions function" {
    run bash -c "grep -q '^lookup_positions()' '$SCRIPT'"
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
# Context line mapping tests
# =============================================================================

@test "diff-position-mapper: maps context lines (unchanged lines in diff)" {
    # Context lines are lines with a space prefix in the diff - they appear in
    # both old and new versions. The mapper should include them so comments can
    # reference unchanged code visible in the diff view.
    local diff
    diff=$(cat "$FIXTURES_DIR/large-changes.diff")

    # Line 1 in large-changes.diff is a context line: " {"
    # (the opening brace of package.json, unchanged between versions)
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [{path: "package-lock.json", line: 1}]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # Context line should be mapped successfully (no error)
    local error
    error=$(echo "$output" | jq -r '.mappings[0].error // "none"')
    [ "$error" = "none" ]

    # Context lines map to RIGHT side
    local side
    side=$(echo "$output" | jq -r '.mappings[0].side')
    [ "$side" = "RIGHT" ]

    # Line number should be preserved
    local line
    line=$(echo "$output" | jq '.mappings[0].line')
    [ "$line" = "1" ]
}

@test "diff-position-mapper: maps multiple context lines" {
    local diff
    diff=$(cat "$FIXTURES_DIR/large-changes.diff")

    # Lines 1, 2, 3 are all context lines in the diff
    local input
    input=$(jq -n --arg d "$diff" '{diff: $d, targets: [
        {path: "package-lock.json", line: 1},
        {path: "package-lock.json", line: 2},
        {path: "package-lock.json", line: 3}
    ]}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # All three context lines should be mapped successfully
    local error_count
    error_count=$(echo "$output" | jq '[.mappings[] | select(.error != null)] | length')
    [ "$error_count" = "0" ]

    # All should have side RIGHT
    local right_count
    right_count=$(echo "$output" | jq '[.mappings[] | select(.side == "RIGHT")] | length')
    [ "$right_count" = "3" ]
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

# =============================================================================
# --diff-file flag tests (new functionality)
# =============================================================================

@test "diff-position-mapper: accepts --diff-file flag" {
    local diff_file="$BATS_TEST_TMPDIR/test.diff"
    cat "$FIXTURES_DIR/simple-single-file.diff" > "$diff_file"

    local input='{"targets": [{"path": "src/utils.ts", "line": 1}]}'
    run bash -c "echo '$input' | '$SCRIPT' --diff-file '$diff_file'"
    [ "$status" -eq 0 ]
}

@test "diff-position-mapper: --diff-file produces same output as stdin" {
    local diff_file="$BATS_TEST_TMPDIR/test.diff"
    cat "$FIXTURES_DIR/simple-single-file.diff" > "$diff_file"

    local input='{"targets": [{"path": "src/utils.ts", "line": 1}]}'

    # Run with stdin (via jq)
    local stdin_output
    stdin_output=$(bash -c "cat '$FIXTURES_DIR/simple-single-file.diff' | jq -Rs '{diff: ., targets: [{path: \"src/utils.ts\", line: 1}]}' | '$SCRIPT'")

    # Run with --diff-file
    local file_output
    file_output=$(bash -c "echo '$input' | '$SCRIPT' --diff-file '$diff_file'")

    # Should produce identical output
    [ "$stdin_output" = "$file_output" ]
}

@test "diff-position-mapper: --diff-file with nonexistent file fails" {
    local input='{"targets": []}'
    run bash -c "echo '$input' | '$SCRIPT' --diff-file /nonexistent/path/file.diff"
    [ "$status" -ne 0 ]
}

@test "diff-position-mapper: --diff-file reads correct diff content" {
    local diff_file="$BATS_TEST_TMPDIR/test.diff"
    cat "$FIXTURES_DIR/simple-single-file.diff" > "$diff_file"

    local input='{"targets": [{"path": "src/utils.ts", "line": 1}]}'

    run bash -c "echo '$input' | '$SCRIPT' --diff-file '$diff_file'"
    [ "$status" -eq 0 ]

    # Should successfully map the line (no error)
    local error
    error=$(echo "$output" | jq -r '.mappings[0].error // "none"')
    [ "$error" = "none" ]
}

@test "diff-position-mapper: --diff-file with empty file fails appropriately" {
    local diff_file="$BATS_TEST_TMPDIR/empty.diff"
    touch "$diff_file"

    local input='{"targets": []}'
    run bash -c "echo '$input' | '$SCRIPT' --diff-file '$diff_file'"
    [ "$status" -ne 0 ]
}

@test "diff-position-mapper: --diff-file with large diff file" {
    local diff_file="$BATS_TEST_TMPDIR/large.diff"
    cat "$FIXTURES_DIR/large-changes.diff" > "$diff_file"

    local input='{"targets": [{"path": "package-lock.json", "line": 1}]}'

    run bash -c "echo '$input' | '$SCRIPT' --diff-file '$diff_file'"
    [ "$status" -eq 0 ]

    # Should successfully process
    local error
    error=$(echo "$output" | jq -r '.mappings[0].error // "none"')
    [ "$error" = "none" ]
}

@test "diff-position-mapper: --diff-file with multi-file diff" {
    local diff_file="$BATS_TEST_TMPDIR/multifile.diff"
    cat "$FIXTURES_DIR/python-flask.diff" > "$diff_file"

    local input='{"targets": [{"path": "api/app.py", "line": 1}]}'

    run bash -c "echo '$input' | '$SCRIPT' --diff-file '$diff_file'"
    [ "$status" -eq 0 ]
}

map_deleted_line_targets() {
    printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/targets.json"
    run bash -c '"$1" --diff-file "$2" < "$3"' _ "$SCRIPT" \
        "$FIXTURES_DIR/deleted-line-anchors.diff" "$BATS_TEST_TMPDIR/targets.json"
    [ "$status" -eq 0 ]
}

@test "diff-position-mapper: maps fully deleted file lines to LEFT by default" {
    map_deleted_line_targets '{"targets":[{"path":"src/deleted.py","line":1},{"path":"src/deleted.py","line":4}]}'

    echo "$output" | jq -e '.mappings == [
        {path: "src/deleted.py", line: 1, side: "LEFT"},
        {path: "src/deleted.py", line: 4, side: "LEFT"}
    ]'
}

@test "diff-position-mapper: explicit LEFT resolves removed lines sharing RIGHT line numbers" {
    map_deleted_line_targets '{"targets":[{"path":"src/mixed.py","line":11,"side":"LEFT"},{"path":"src/mixed.py","line":11}]}'

    echo "$output" | jq -e '.mappings == [
        {path: "src/mixed.py", line: 11, side: "LEFT"},
        {path: "src/mixed.py", line: 11, side: "RIGHT"}
    ]'
}

@test "diff-position-mapper: unchanged context only maps on RIGHT" {
    map_deleted_line_targets '{"targets":[{"path":"src/mixed.py","line":13,"side":"LEFT"},{"path":"src/mixed.py","line":13},{"path":"src/mixed.py","line":12,"side":"RIGHT"}]}'

    echo "$output" | jq -e '.mappings[0].error == "line not in diff" and .mappings[1].error == "line not in diff"'
    echo "$output" | jq -e '.mappings[2] == {path: "src/mixed.py", line: 12, side: "RIGHT"}'
}

@test "diff-position-mapper: explicit side never falls back to the opposite side" {
    map_deleted_line_targets '{"targets":[{"path":"src/deleted.py","line":1,"side":"RIGHT"},{"path":"src/added.py","line":1,"side":"LEFT"}]}'

    echo "$output" | jq -e '.mappings | length == 2 and all(.[]; .error == "line not in diff")'
}

@test "diff-position-mapper: hunk content beginning with file-header markers is mappable" {
    map_deleted_line_targets '{"targets":[{"path":"src/deleted.py","line":3,"side":"LEFT"},{"path":"src/markers.txt","line":1,"side":"LEFT"},{"path":"src/markers.txt","line":1,"side":"RIGHT"}]}'

    echo "$output" | jq -e '.mappings | length == 3 and all(.[]; has("error") | not)'
    echo "$output" | jq -e '[.mappings[].side] == ["LEFT", "LEFT", "RIGHT"]'
}

@test "diff-position-mapper: mixed batches preserve target order defaults and mapping errors" {
    map_deleted_line_targets '{"targets":[
        {"path":"src/mixed.py","line":11},
        {"path":"src/mixed.py","line":11,"side":"LEFT"},
        {"path":"src/added.py","line":1,"side":"RIGHT"},
        {"path":"src/missing.py","line":1},
        {"path":"src/mixed.py","line":999,"side":"LEFT"},
        {"path":"src/deleted.py","line":1}
    ]}'

    echo "$output" | jq -e '.mappings == [
        {path: "src/mixed.py", line: 11, side: "RIGHT"},
        {path: "src/mixed.py", line: 11, side: "LEFT"},
        {path: "src/added.py", line: 1, side: "RIGHT"},
        {path: "src/missing.py", line: 1, error: "file not in diff"},
        {path: "src/mixed.py", line: 999, error: "line not in diff"},
        {path: "src/deleted.py", line: 1, side: "LEFT"}
    ]'
}

@test "diff-position-mapper: an invalid side rejects the batch without partial mappings" {
    printf '%s\n' '{"targets":[{"path":"src/mixed.py","line":11},{"path":"src/mixed.py","line":11,"side":"BOTH"}]}' > "$BATS_TEST_TMPDIR/targets.json"

    run bash -c '"$1" --diff-file "$2" < "$3"' _ "$SCRIPT" \
        "$FIXTURES_DIR/deleted-line-anchors.diff" "$BATS_TEST_TMPDIR/targets.json"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Target side must be LEFT or RIGHT"* ]]
    [[ "$output" != *'"mappings"'* ]]
}

@test "diff-position-mapper: rename metadata resolves header separators within either path" {
    jq -n '{targets: [
        ["src/renamed.py", "src/foo b/renamed.py"][] as $path
        | ["LEFT", "RIGHT"][] as $side
        | {path: $path, line: 2, side: $side}
    ]}' > "$BATS_TEST_TMPDIR/targets.json"

    run bash -c '"$1" --diff-file "$2" < "$3"' _ "$SCRIPT" \
        "$FIXTURES_DIR/ambiguous-rename-paths.diff" "$BATS_TEST_TMPDIR/targets.json"

    [ "$status" -eq 0 ]
    echo "$output" | jq -e --slurpfile input "$BATS_TEST_TMPDIR/targets.json" '.mappings == $input[0].targets'
}
