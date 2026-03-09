#!/usr/bin/env bats
# Tests for chunk-diff.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/chunk-diff.sh"
    FIXTURES_DIR="$PROJECT_ROOT/tests/fixtures/diffs"
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "chunk-diff: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "chunk-diff: uses set -euo pipefail" {
    run bash -c "head -30 '$SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "chunk-diff: has main function" {
    run bash -c "grep -q '^main()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "chunk-diff: can be sourced without executing main" {
    output=$(source "$SCRIPT" 2>&1)
    [ -z "$output" ]
}

# =============================================================================
# Input validation tests
# =============================================================================

@test "chunk-diff: rejects invalid JSON input" {
    run bash -c "echo 'not json' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid JSON"* ]]
}

@test "chunk-diff: outputs valid JSON on success" {
    run bash -c "echo '{\"diff\": \"\"}' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.' > /dev/null
}

# =============================================================================
# Empty/small diff tests
# =============================================================================

@test "chunk-diff: empty diff returns chunked false" {
    run bash -c "echo '{\"diff\": \"\"}' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == false'
    echo "$output" | jq -e '.reason == "empty diff"'
}

@test "chunk-diff: null diff returns chunked false" {
    run bash -c "echo '{\"diff\": null}' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == false'
}

@test "chunk-diff: small diff returns chunked false with reason" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" '{"diff": $diff}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == false'
    [[ "$(echo "$output" | jq -r '.reason')" == *"below threshold"* ]]
}

@test "chunk-diff: small diff has no chunks array" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" '{"diff": $diff}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    # When below threshold, chunks field should not be present
    has_chunks=$(echo "$output" | jq 'has("chunks")')
    [ "$has_chunks" = "false" ]
}

# =============================================================================
# Large diff chunking tests
# =============================================================================

@test "chunk-diff: large diff with many files returns chunked true" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'
}

@test "chunk-diff: chunked output includes chunk_count" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    chunk_count=$(echo "$output" | jq '.chunk_count')
    [ "$chunk_count" -gt 1 ]
}

@test "chunk-diff: chunked output includes chunks array" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunks | type == "array"'
    echo "$output" | jq -e '.chunks | length > 0'
}

@test "chunk-diff: each chunk has required fields" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    # Every chunk must have id, label, files, diff, size_kb
    echo "$output" | jq -e '.chunks | all(has("id", "label", "files", "diff", "size_kb"))'
}

@test "chunk-diff: chunk ids are sequential starting at 1" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    first_id=$(echo "$output" | jq '.chunks[0].id')
    [ "$first_id" -eq 1 ]
}

# =============================================================================
# Test file pairing tests
# =============================================================================

@test "chunk-diff: test files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # For each test file (test_file0.py, test_file1.py, test_file2.py),
    # its implementation file (file0.py, file1.py, file2.py) should be in the same chunk
    for i in 0 1 2; do
        impl="backend/api/file${i}.py"
        test="backend/api/test_file${i}.py"
        # Find which chunk has the test file, then check that the impl is there too
        impl_chunk=$(echo "$output" | jq --arg f "$impl" '[.chunks[] | select(.files | index($f))] | .[0].id')
        test_chunk=$(echo "$output" | jq --arg f "$test" '[.chunks[] | select(.files | index($f))] | .[0].id')
        [ "$impl_chunk" = "$test_chunk" ]
    done
}

# =============================================================================
# Directory grouping tests
# =============================================================================

@test "chunk-diff: files in same directory tend to group together" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 10}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # frontend/components has 5 files. They should all be in the same chunk
    # since they sort adjacently and 5 files fits within the 10-file limit.
    component_chunks=$(echo "$output" | jq '[.chunks[] | select(.files | any(startswith("frontend/components/")))] | length')
    [ "$component_chunks" -eq 1 ]
}

# =============================================================================
# Diff integrity tests
# =============================================================================

@test "chunk-diff: chunk diffs start with diff --git" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # Every chunk's diff should start with "diff --git"
    echo "$output" | jq -e '.chunks | all(.diff | startswith("diff --git"))'
}

@test "chunk-diff: no files lost or duplicated across chunks" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # Count unique files
    unique_count=$(echo "$output" | jq '[.chunks[].files[]] | unique | length')
    total_count=$(echo "$output" | jq '[.chunks[].files[]] | length')
    # No duplicates
    [ "$unique_count" = "$total_count" ]

    # Total files should equal the number of diff segments in the original
    expected_count=$(echo "$diff_content" | grep -c '^diff --git' || true)
    [ "$total_count" -eq "$expected_count" ]
}

# =============================================================================
# Configuration override tests
# =============================================================================

@test "chunk-diff: custom config overrides defaults" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")

    # With very low threshold, even a small diff should be chunked
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 5, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 5}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # Should be chunked since there are >5 files
    echo "$output" | jq -e '.chunked == true'

    # Each chunk should have at most 5 files
    echo "$output" | jq -e '.chunks | all(.files | length <= 5)'
}

@test "chunk-diff: respects max_files_per_chunk" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 5, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 6}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'
    echo "$output" | jq -e '.chunks | all(.files | length <= 6)'
}

@test "chunk-diff: missing config fields use defaults" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    # No config at all - should use defaults
    local input
    input=$(jq -n --arg diff "$diff_content" '{"diff": $diff}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    # Small diff should not be chunked with default thresholds
    echo "$output" | jq -e '.chunked == false'
}

# =============================================================================
# Single file edge case tests
# =============================================================================

@test "chunk-diff: single file diff returns chunked false" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/simple-single-file.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 0, "min_chunk_threshold_kb": 0}}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    # A single file can never produce multiple chunks
    echo "$output" | jq -e '.chunked == false'
}

@test "chunk-diff: all files in one directory may produce single chunk" {
    # Generate a diff where all files are in the same directory
    local diff=""
    for i in $(seq 1 5); do
        diff="${diff}diff --git a/src/file${i}.py b/src/file${i}.py
index abc..def 100644
--- a/src/file${i}.py
+++ b/src/file${i}.py
@@ -1,3 +1,4 @@
+line ${i}
"
    done

    local input
    input=$(jq -n --arg diff "$diff" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 3, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 10}}')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    # 5 files in one directory with max 10 per chunk should fit in one chunk
    echo "$output" | jq -e '.chunked == false'
}

# =============================================================================
# Chunk label tests
# =============================================================================

@test "chunk-diff: chunk labels contain file count" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    # Every label should contain "files"
    echo "$output" | jq -e '.chunks | all(.label | contains("files"))'
}

# =============================================================================
# Reason string tests
# =============================================================================

@test "chunk-diff: chunked reason mentions exceeds threshold" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '.reason')" == *"exceeds threshold"* ]]
}

# =============================================================================
# Size-based splitting tests
# =============================================================================

@test "chunk-diff: size-based splitting with low max_chunk_size_kb" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    # Use a very low max_chunk_size_kb (1KB) but high max_files_per_chunk to force
    # size-based splitting rather than file-count-based splitting
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 5, "min_chunk_threshold_kb": 0, "max_chunk_size_kb": 1, "max_files_per_chunk": 100}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'
    # With 1KB limit, there should be many chunks since each file is ~1KB+
    chunk_count=$(echo "$output" | jq '.chunk_count')
    [ "$chunk_count" -gt 2 ]
}

# =============================================================================
# chunk_count consistency tests
# =============================================================================

@test "chunk-diff: chunk_count equals chunks array length" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'
    # Verify chunk_count matches the actual number of chunks and ids are sequential
    echo "$output" | jq -e '.chunk_count == (.chunks | length)'
    echo "$output" | jq -e '[.chunks[].id] == [range(1; (.chunks | length) + 1)]'
}

# =============================================================================
# Additional test-file pairing pattern tests
# =============================================================================

@test "chunk-diff: Go _test.go files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # handler_test.go should be in the same chunk as handler.go
    impl_chunk=$(echo "$output" | jq --arg f "backend/services/handler.go" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "backend/services/handler_test.go" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}

@test "chunk-diff: JS .test.ts files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # format.test.ts should be in the same chunk as format.ts
    impl_chunk=$(echo "$output" | jq --arg f "frontend/utils/format.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "frontend/utils/format.test.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}

@test "chunk-diff: __tests__ directory files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # frontend/lib/__tests__/helpers.ts should be in the same chunk as frontend/lib/helpers.ts
    impl_chunk=$(echo "$output" | jq --arg f "frontend/lib/helpers.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "frontend/lib/__tests__/helpers.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}

@test "chunk-diff: Ruby _spec.rb files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # parser_spec.rb should be in the same chunk as parser.rb
    impl_chunk=$(echo "$output" | jq --arg f "backend/services/parser.rb" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "backend/services/parser_spec.rb" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}

@test "chunk-diff: Angular .spec.ts files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # app.component.spec.ts should be in the same chunk as app.component.ts
    impl_chunk=$(echo "$output" | jq --arg f "frontend/components/app.component.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "frontend/components/app.component.spec.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}

@test "chunk-diff: generic _test suffix files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # utils_test.py should be in the same chunk as utils.py
    impl_chunk=$(echo "$output" | jq --arg f "backend/models/utils.py" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "backend/models/utils_test.py" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}

# =============================================================================
# Threshold boundary tests
# =============================================================================

@test "chunk-diff: exceeds file threshold only still triggers chunking" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    # High KB threshold (won't be exceeded), low file threshold (will be exceeded)
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 9999, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'
}

@test "chunk-diff: exceeds KB threshold only still triggers chunking" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    # Low KB threshold (will be exceeded), high file threshold (won't be exceeded)
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 9999, "min_chunk_threshold_kb": 1, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'
}

# =============================================================================
# file_metadata integration tests
# =============================================================================

@test "chunk-diff: file_metadata likely_test_path pairs files via forward mapping" {
    # Build a small diff with four files
    local diff=""
    for f in src/app.py src/my_app_test.py src/utils.py src/helper.py; do
        diff="${diff}diff --git a/$f b/$f
index abc..def 100644
--- a/$f
+++ b/$f
@@ -1,3 +1,4 @@
+line from $f
"
    done

    # my_app_test.py would not be paired by filename patterns (no matching impl),
    # but file_metadata says app.py's likely_test_path is my_app_test.py
    local metadata
    metadata=$(jq -nc '{modified_files: [
        {path: "src/app.py", is_test: false, likely_test_path: "src/my_app_test.py"},
        {path: "src/my_app_test.py", is_test: true, likely_test_path: ""},
        {path: "src/utils.py", is_test: false, likely_test_path: ""},
        {path: "src/helper.py", is_test: false, likely_test_path: ""}
    ]}')
    local input
    input=$(jq -n --arg diff "$diff" --argjson meta "$metadata" \
        '{"diff": $diff, "file_metadata": $meta, "config": {"min_chunk_threshold_files": 2, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 2}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'

    # app.py and my_app_test.py should be in the same chunk via likely_test_path
    impl_chunk=$(echo "$output" | jq --arg f "src/app.py" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "src/my_app_test.py" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}

@test "chunk-diff: file_metadata is_test=false skips pattern matching" {
    # Build a diff with a file named test_config.py that is NOT a test file
    local diff=""
    for f in src/test_config.py src/config.py src/other.py src/another.py; do
        diff="${diff}diff --git a/$f b/$f
index abc..def 100644
--- a/$f
+++ b/$f
@@ -1,3 +1,4 @@
+line from $f
"
    done

    # Metadata says test_config.py is NOT a test (despite the name)
    local metadata
    metadata=$(jq -nc '{modified_files: [
        {path: "src/test_config.py", is_test: false, likely_test_path: ""},
        {path: "src/config.py", is_test: false, likely_test_path: ""},
        {path: "src/other.py", is_test: false, likely_test_path: ""},
        {path: "src/another.py", is_test: false, likely_test_path: ""}
    ]}')
    local input
    input=$(jq -n --arg diff "$diff" --argjson meta "$metadata" \
        '{"diff": $diff, "file_metadata": $meta, "config": {"min_chunk_threshold_files": 2, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 2}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'

    # test_config.py should NOT be paired with config.py since metadata says it's not a test
    impl_chunk=$(echo "$output" | jq --arg f "src/config.py" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "src/test_config.py" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" != "$test_chunk" ]
}

# =============================================================================
# Size-based splitting tests
# =============================================================================

@test "chunk-diff: size-based splitting with low max_chunk_size_kb" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    # Use a very low max_chunk_size_kb (1KB) but high max_files_per_chunk to force
    # size-based splitting rather than file-count-based splitting
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 5, "min_chunk_threshold_kb": 0, "max_chunk_size_kb": 1, "max_files_per_chunk": 100}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'
    # With 1KB limit, there should be many chunks since each file is ~1KB+
    chunk_count=$(echo "$output" | jq '.chunk_count')
    [ "$chunk_count" -gt 2 ]
}

# =============================================================================
# chunk_count consistency tests
# =============================================================================

@test "chunk-diff: chunk_count equals chunks array length" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.chunked == true'
    # Verify chunk_count matches the actual number of chunks and ids are sequential
    echo "$output" | jq -e '.chunk_count == (.chunks | length)'
    echo "$output" | jq -e '[.chunks[].id] == [range(1; (.chunks | length) + 1)]'
}

# =============================================================================
# Additional test-file pairing pattern tests
# =============================================================================

@test "chunk-diff: Go _test.go files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # handler_test.go should be in the same chunk as handler.go
    impl_chunk=$(echo "$output" | jq --arg f "backend/services/handler.go" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "backend/services/handler_test.go" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}

@test "chunk-diff: JS .test.ts files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # format.test.ts should be in the same chunk as format.ts
    impl_chunk=$(echo "$output" | jq --arg f "frontend/utils/format.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "frontend/utils/format.test.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}

@test "chunk-diff: __tests__ directory files are paired with implementation files" {
    local diff_content
    diff_content=$(cat "$FIXTURES_DIR/multi-directory.diff")
    local input
    input=$(jq -n --arg diff "$diff_content" \
        '{"diff": $diff, "config": {"min_chunk_threshold_files": 10, "min_chunk_threshold_kb": 0, "max_files_per_chunk": 8}}')

    run bash -c "printf '%s' '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    # frontend/lib/__tests__/helpers.ts should be in the same chunk as frontend/lib/helpers.ts
    impl_chunk=$(echo "$output" | jq --arg f "frontend/lib/helpers.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    test_chunk=$(echo "$output" | jq --arg f "frontend/lib/__tests__/helpers.ts" '[.chunks[] | select(.files | index($f))] | .[0].id')
    [ "$impl_chunk" = "$test_chunk" ]
}
