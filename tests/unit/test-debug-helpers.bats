#!/usr/bin/env bats

# Tests for lib/helpers/debug-helpers.sh

setup() {
    # Set PROJECT_ROOT
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Load the debug helpers
    source "$PROJECT_ROOT/skills/review-code/scripts/helpers/debug-helpers.sh"

    # Create temp directory for testing
    TEST_DEBUG_DIR=$(mktemp -d)
    export REVIEW_CODE_DEBUG_PATH="$TEST_DEBUG_DIR"
}

teardown() {
    # Clean up test directory
    rm -rf "$TEST_DEBUG_DIR"
    unset REVIEW_CODE_DEBUG
    unset DEBUG_SESSION_DIR
    unset REVIEW_CODE_DEBUG_PATH
}

@test "is_debug_enabled returns 1 when DEBUG mode is off" {
    export REVIEW_CODE_DEBUG=0
    run is_debug_enabled
    [ "$status" -eq 1 ]
}

@test "is_debug_enabled returns 0 when DEBUG mode is on" {
    export REVIEW_CODE_DEBUG=1
    run is_debug_enabled
    [ "$status" -eq 0 ]
}

@test "is_debug_enabled returns 1 when REVIEW_CODE_DEBUG is unset" {
    unset REVIEW_CODE_DEBUG
    run is_debug_enabled
    [ "$status" -eq 1 ]
}

@test "debug_init creates session directory with correct structure" {
    export REVIEW_CODE_DEBUG=1

    debug_init "pr-123" "posthog" "posthog" "pr"

    # Check directory was created
    [ -d "$DEBUG_SESSION_DIR" ]

    # Check session metadata exists
    [ -f "$DEBUG_SESSION_DIR/session.json" ]

    # Verify session metadata contents
    run jq -r '.identifier' "$DEBUG_SESSION_DIR/session.json"
    [ "$output" = "pr-123" ]

    run jq -r '.org' "$DEBUG_SESSION_DIR/session.json"
    [ "$output" = "posthog" ]

    run jq -r '.repo' "$DEBUG_SESSION_DIR/session.json"
    [ "$output" = "posthog" ]

    run jq -r '.mode' "$DEBUG_SESSION_DIR/session.json"
    [ "$output" = "pr" ]
}

@test "debug_init does nothing when DEBUG mode is off" {
    export REVIEW_CODE_DEBUG=0

    debug_init "pr-123" "posthog" "posthog" "pr"

    # Directory should not be created
    [ -z "$DEBUG_SESSION_DIR" ] || [ ! -d "$DEBUG_SESSION_DIR" ]
}

@test "debug_save creates stage directory and saves content" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    debug_save "01-test-stage" "test.txt" "test content"

    # Check file was created with correct content
    [ -f "$DEBUG_SESSION_DIR/01-test-stage/test.txt" ]
    run cat "$DEBUG_SESSION_DIR/01-test-stage/test.txt"
    [ "$output" = "test content" ]
}

@test "debug_save does nothing when DEBUG mode is off" {
    export REVIEW_CODE_DEBUG=0

    debug_save "01-test-stage" "test.txt" "test content"

    # Nothing should be created
    [ -z "$DEBUG_SESSION_DIR" ] || [ ! -f "$DEBUG_SESSION_DIR/01-test-stage/test.txt" ]
}

@test "debug_save_file copies file to stage directory" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    # Create a source file
    local source_file="$TEST_DEBUG_DIR/source.txt"
    echo "source content" > "$source_file"

    debug_save_file "02-test-stage" "copied.txt" "$source_file"

    # Check file was copied with correct content
    [ -f "$DEBUG_SESSION_DIR/02-test-stage/copied.txt" ]
    run cat "$DEBUG_SESSION_DIR/02-test-stage/copied.txt"
    [ "$output" = "source content" ]
}

@test "debug_save_json saves pretty-formatted JSON" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    echo '{"foo":"bar","baz":123}' | debug_save_json "03-test-stage" "output.json"

    # Check file exists and is valid JSON
    [ -f "$DEBUG_SESSION_DIR/03-test-stage/output.json" ]

    run jq -r '.foo' "$DEBUG_SESSION_DIR/03-test-stage/output.json"
    [ "$output" = "bar" ]

    run jq -r '.baz' "$DEBUG_SESSION_DIR/03-test-stage/output.json"
    [ "$output" = "123" ]
}

@test "debug_save_json handles malformed JSON gracefully" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    echo 'not valid json' | debug_save_json "03-test-stage" "invalid.json"

    # Should save raw content even if not valid JSON
    [ -f "$DEBUG_SESSION_DIR/03-test-stage/invalid.json" ]
    run grep -F "not valid json" "$DEBUG_SESSION_DIR/03-test-stage/invalid.json"
    [ "$status" -eq 0 ]
}

@test "debug_log_command saves command string" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    debug_log_command "04-commands" "Test command" echo "hello world"

    # Check commands.log exists and contains command
    [ -f "$DEBUG_SESSION_DIR/04-commands/commands.log" ]
    run grep -F "Command: echo hello world" "$DEBUG_SESSION_DIR/04-commands/commands.log"
    [ "$status" -eq 0 ]
}

@test "debug_log_command captures stdout" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    debug_log_command "04-commands" "Echo test" echo "output to stdout"

    # Check stdout was captured
    [ -f "$DEBUG_SESSION_DIR/04-commands/stdout.log" ]
    run cat "$DEBUG_SESSION_DIR/04-commands/stdout.log"
    [ "$output" = "output to stdout" ]
}

@test "debug_log_command captures stderr" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    debug_log_command "04-commands" "Error test" sh -c 'echo "error message" >&2'

    # Check stderr was captured
    [ -f "$DEBUG_SESSION_DIR/04-commands/stderr.log" ]
    run cat "$DEBUG_SESSION_DIR/04-commands/stderr.log"
    [ "$output" = "error message" ]
}

@test "debug_log_command records exit code for successful command" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    debug_log_command "04-commands" "Success test" true

    run grep -F "Exit code: 0" "$DEBUG_SESSION_DIR/04-commands/commands.log"
    [ "$status" -eq 0 ]
}

@test "debug_log_command records exit code for failed command" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    # Should capture failure but not fail the test itself
    debug_log_command "04-commands" "Failure test" false || true

    run grep -F "Exit code: 1" "$DEBUG_SESSION_DIR/04-commands/commands.log"
    [ "$status" -eq 0 ]
}

@test "debug_time creates timing entries" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    debug_time "05-timing" "start"
    debug_time "05-timing" "end"

    # Check timing file exists
    [ -f "$DEBUG_SESSION_DIR/timing.ndjson" ]

    # Verify entries are valid NDJSON
    run jq -s 'length' "$DEBUG_SESSION_DIR/timing.ndjson"
    [ "$output" = "2" ]

    # Check start event
    run jq -r 'select(.event == "start") | .stage' "$DEBUG_SESSION_DIR/timing.ndjson"
    [ "$output" = "05-timing" ]

    # Check end event
    run jq -r 'select(.event == "end") | .stage' "$DEBUG_SESSION_DIR/timing.ndjson"
    [ "$output" = "05-timing" ]
}

@test "debug_trace appends messages with timestamps" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    debug_trace "06-trace" "First message"
    debug_trace "06-trace" "Second message"

    # Check trace file exists
    [ -f "$DEBUG_SESSION_DIR/06-trace/trace.log" ]

    # Check both messages are present
    run grep -F "First message" "$DEBUG_SESSION_DIR/06-trace/trace.log"
    [ "$status" -eq 0 ]

    run grep -F "Second message" "$DEBUG_SESSION_DIR/06-trace/trace.log"
    [ "$status" -eq 0 ]

    # Check timestamps are present
    run grep -E '\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]' "$DEBUG_SESSION_DIR/06-trace/trace.log"
    [ "$status" -eq 0 ]
}

@test "debug_stats saves key-value pairs as JSON" {
    export REVIEW_CODE_DEBUG=1
    debug_init "test" "org" "repo" "local"

    debug_stats "07-stats" lines_before "1000" lines_after "200" reduction "80"

    # Check stats file exists and has correct values
    [ -f "$DEBUG_SESSION_DIR/07-stats/stats.json" ]

    run jq -r '.lines_before' "$DEBUG_SESSION_DIR/07-stats/stats.json"
    [ "$output" = "1000" ]

    run jq -r '.lines_after' "$DEBUG_SESSION_DIR/07-stats/stats.json"
    [ "$output" = "200" ]

    run jq -r '.reduction' "$DEBUG_SESSION_DIR/07-stats/stats.json"
    [ "$output" = "80" ]
}

@test "debug_finalize creates README.md file" {
    export REVIEW_CODE_DEBUG=1
    debug_init "pr-456" "testorg" "testrepo" "pr"

    # Add some debug artifacts
    debug_save "01-stage" "file.txt" "content"
    debug_time "01-stage" "start"
    debug_time "01-stage" "end"

    debug_finalize

    # Check README.md file exists
    [ -f "$DEBUG_SESSION_DIR/README.md" ]

    # Verify it contains key information
    run grep -F "Review Code Debug Summary" "$DEBUG_SESSION_DIR/README.md"
    [ "$status" -eq 0 ]

    run grep -F "Mode: pr" "$DEBUG_SESSION_DIR/README.md"
    [ "$status" -eq 0 ]

    run grep -F "Identifier: pr-456" "$DEBUG_SESSION_DIR/README.md"
    [ "$status" -eq 0 ]
}

@test "all debug functions are no-ops when DEBUG mode is off" {
    export REVIEW_CODE_DEBUG=0

    # None of these should create any files
    debug_init "test" "org" "repo" "local"
    debug_save "stage" "file.txt" "content"
    debug_save_json "stage" "file.json" <<< '{"test":true}'
    debug_log_command "stage" "desc" echo "test"
    debug_time "stage" "start"
    debug_trace "stage" "message"
    debug_stats "stage" key value
    debug_finalize

    # Verify no debug directory was created
    run find "$TEST_DEBUG_DIR" -type f
    [ -z "$output" ]
}
