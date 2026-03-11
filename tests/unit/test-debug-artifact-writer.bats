#!/usr/bin/env bats
# Tests for debug-artifact-writer.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/debug-artifact-writer.sh"

    # Create a temp directory that mimics the expected debug path
    TEST_DEBUG_BASE="$BATS_TEST_TMPDIR/.cache/review-code/debug"
    mkdir -p "$TEST_DEBUG_BASE"
    TEST_DEBUG_DIR="$TEST_DEBUG_BASE/test-session-$$"
    mkdir -p "$TEST_DEBUG_DIR"
}

# Helper: run the script with HOME overridden to match TEST_DEBUG_DIR's prefix
_run_writer() {
    run bash -c "export HOME='$BATS_TEST_TMPDIR'; $1"
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "debug-artifact-writer: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "debug-artifact-writer: is executable" {
    [ -x "$SCRIPT" ]
}

# =============================================================================
# Save action tests
# =============================================================================

@test "debug-artifact-writer: save creates file at correct path" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"save\",\"debug_dir\":\$dir,\"stage\":\"08-context-explorer\",\"filename\":\"result.md\",\"content\":\"# Explorer output\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DEBUG_DIR/08-context-explorer/result.md" ]
    run cat "$TEST_DEBUG_DIR/08-context-explorer/result.md"
    [[ "$output" == *"Explorer output"* ]]
}

@test "debug-artifact-writer: save creates stage directory if missing" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"save\",\"debug_dir\":\$dir,\"stage\":\"09-per-chunk\",\"filename\":\"chunk-1-prompt.md\",\"content\":\"test content\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -d "$TEST_DEBUG_DIR/09-per-chunk" ]
    [ -f "$TEST_DEBUG_DIR/09-per-chunk/chunk-1-prompt.md" ]
}

@test "debug-artifact-writer: save preserves content exactly" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' --arg content 'hello world' \
        '{\"action\":\"save\",\"debug_dir\":\$dir,\"stage\":\"test-stage\",\"filename\":\"exact.txt\",\"content\":\$content}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    local saved
    saved=$(cat "$TEST_DEBUG_DIR/test-stage/exact.txt")
    [ "$saved" = "hello world" ]
}

# =============================================================================
# Time action tests
# =============================================================================

@test "debug-artifact-writer: time appends to timing.ndjson" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"time\",\"debug_dir\":\$dir,\"stage\":\"08-context-explorer\",\"event\":\"start\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DEBUG_DIR/timing.ndjson" ]
    run jq -e '.stage == "08-context-explorer" and .event == "start"' "$TEST_DEBUG_DIR/timing.ndjson"
    [ "$status" -eq 0 ]
}

@test "debug-artifact-writer: time appends multiple events" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"time\",\"debug_dir\":\$dir,\"stage\":\"10-agent-dispatch\",\"event\":\"start\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]

    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"time\",\"debug_dir\":\$dir,\"stage\":\"10-agent-dispatch\",\"event\":\"end\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]

    local line_count
    line_count=$(wc -l < "$TEST_DEBUG_DIR/timing.ndjson" | tr -d ' ')
    [ "$line_count" -eq 2 ]
}

@test "debug-artifact-writer: time event has numeric timestamp" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"time\",\"debug_dir\":\$dir,\"stage\":\"test\",\"event\":\"start\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]

    run jq -e '.timestamp | type == "number"' "$TEST_DEBUG_DIR/timing.ndjson"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Stats action tests
# =============================================================================

@test "debug-artifact-writer: stats writes stats.json" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"stats\",\"debug_dir\":\$dir,\"stage\":\"10-agent-dispatch\",\"data\":{\"agent_count\":\"7\",\"chunk_count\":\"2\"}}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DEBUG_DIR/10-agent-dispatch/stats.json" ]
    run jq -e '.agent_count == "7"' "$TEST_DEBUG_DIR/10-agent-dispatch/stats.json"
    [ "$status" -eq 0 ]
}

@test "debug-artifact-writer: stats with empty data writes empty object" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"stats\",\"debug_dir\":\$dir,\"stage\":\"test-stage\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -f "$TEST_DEBUG_DIR/test-stage/stats.json" ]
    run jq -e '. == {}' "$TEST_DEBUG_DIR/test-stage/stats.json"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Validation tests
# =============================================================================

@test "debug-artifact-writer: rejects invalid debug_dir path" {
    _run_writer "echo '{\"action\":\"save\",\"debug_dir\":\"/tmp/evil\",\"stage\":\"test\",\"filename\":\"test.txt\",\"content\":\"hack\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ ! -f "/tmp/evil/test/test.txt" ]
}

@test "debug-artifact-writer: rejects empty debug_dir" {
    _run_writer "echo '{\"action\":\"save\",\"debug_dir\":\"\",\"stage\":\"test\",\"filename\":\"test.txt\",\"content\":\"data\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "debug-artifact-writer: rejects path traversal in stage" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"save\",\"debug_dir\":\$dir,\"stage\":\"../../../etc\",\"filename\":\"passwd\",\"content\":\"bad\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_DEBUG_DIR/../../../etc/passwd" ]
}

@test "debug-artifact-writer: rejects path traversal in filename" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"save\",\"debug_dir\":\$dir,\"stage\":\"test\",\"filename\":\"../../etc/passwd\",\"content\":\"bad\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_DEBUG_DIR/../../etc/passwd" ]
}

@test "debug-artifact-writer: rejects nonexistent debug_dir" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_BASE/nonexistent-session' \
        '{\"action\":\"save\",\"debug_dir\":\$dir,\"stage\":\"test\",\"filename\":\"test.txt\",\"content\":\"data\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Graceful handling tests
# =============================================================================

@test "debug-artifact-writer: handles missing action gracefully" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"debug_dir\":\$dir,\"stage\":\"test\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "debug-artifact-writer: handles unknown action gracefully" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"unknown\",\"debug_dir\":\$dir,\"stage\":\"test\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "debug-artifact-writer: save with missing stage exits gracefully" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"save\",\"debug_dir\":\$dir,\"filename\":\"test.txt\",\"content\":\"data\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "debug-artifact-writer: save with missing filename exits gracefully" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"save\",\"debug_dir\":\$dir,\"stage\":\"test\",\"content\":\"data\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "debug-artifact-writer: time with missing stage exits gracefully" {
    _run_writer "jq -n --arg dir '$TEST_DEBUG_DIR' \
        '{\"action\":\"time\",\"debug_dir\":\$dir,\"event\":\"start\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "debug-artifact-writer: accepts REVIEW_CODE_DEBUG_PATH prefix" {
    local custom_dir="$BATS_TEST_TMPDIR/custom-debug/custom-session"
    mkdir -p "$custom_dir"

    _run_writer "export REVIEW_CODE_DEBUG_PATH='$BATS_TEST_TMPDIR/custom-debug'; \
        jq -n --arg dir '$custom_dir' \
        '{\"action\":\"save\",\"debug_dir\":\$dir,\"stage\":\"test\",\"filename\":\"ok.txt\",\"content\":\"works\"}' \
        | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -f "$custom_dir/test/ok.txt" ]
}
