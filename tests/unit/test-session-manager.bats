#!/usr/bin/env bats

# Tests for session-manager.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Use a test-specific session directory
    export SESSION_DIR="$BATS_TEST_TMPDIR/test-sessions"
    export CLAUDE_SESSION_DIR="$SESSION_DIR"

    # Source the session manager
    source "$PROJECT_ROOT/lib/session-manager.sh"
}

teardown() {
    # Clean up test session directory
    rm -rf "$SESSION_DIR"
}

# =============================================================================
# sanitize_identifier tests
# =============================================================================

@test "sanitize_identifier: accepts valid alphanumeric string" {
    run sanitize_identifier "valid-name_123"
    [ "$status" -eq 0 ]
    [ "$output" = "valid-name_123" ]
}

@test "sanitize_identifier: accepts hyphens and underscores" {
    run sanitize_identifier "test-command_name"
    [ "$status" -eq 0 ]
    [ "$output" = "test-command_name" ]
}

@test "sanitize_identifier: rejects path with slash" {
    run sanitize_identifier "path/traversal"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid identifier"* ]]
}

@test "sanitize_identifier: rejects path traversal with double dots" {
    run sanitize_identifier "../etc"
    [ "$status" -eq 1 ]
}

@test "sanitize_identifier: rejects absolute path" {
    run sanitize_identifier "/etc/passwd"
    [ "$status" -eq 1 ]
}

@test "sanitize_identifier: rejects special characters" {
    run sanitize_identifier "test;rm -rf"
    [ "$status" -eq 1 ]
}

@test "sanitize_identifier: rejects spaces" {
    run sanitize_identifier "test command"
    [ "$status" -eq 1 ]
}

@test "sanitize_identifier: rejects dollar signs" {
    run sanitize_identifier "test\$var"
    [ "$status" -eq 1 ]
}

@test "sanitize_identifier: rejects backticks" {
    run sanitize_identifier "test\`whoami\`"
    [ "$status" -eq 1 ]
}

@test "sanitize_identifier: rejects command substitution" {
    run sanitize_identifier "test\$(whoami)"
    [ "$status" -eq 1 ]
}

@test "sanitize_identifier: rejects empty string" {
    run sanitize_identifier ""
    [ "$status" -eq 1 ]
}

# =============================================================================
# session_file tests (path resolution)
# =============================================================================

@test "session_file: returns path for valid session ID" {
    run session_file "test-cmd-12345-1234567890"
    [ "$status" -eq 0 ]
    [[ "$output" == "$SESSION_DIR/test-cmd/test-cmd-12345-1234567890.json" ]]
}

@test "session_file: works when directory doesn't exist" {
    # This is the bug that was fixed - should return path even if dir doesn't exist
    run session_file "nonexistent-123-456"
    [ "$status" -eq 0 ]
    [[ "$output" == "$SESSION_DIR/nonexistent/nonexistent-123-456.json" ]]
}

@test "session_file: works when directory exists" {
    # Create the directory first
    mkdir -p "$SESSION_DIR/existing-cmd"

    run session_file "existing-cmd-123-456"
    [ "$status" -eq 0 ]
    [[ "$output" == "$SESSION_DIR/existing-cmd/existing-cmd-123-456.json" ]]
}

@test "session_file: rejects session ID with path traversal" {
    run session_file "../etc-123-456"
    [ "$status" -eq 1 ]
}

@test "session_file: rejects session ID with slash" {
    run session_file "test/cmd-123-456"
    [ "$status" -eq 1 ]
}

@test "session_file: extracts command name correctly" {
    run session_file "my-command-12345-1234567890"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/my-command/"* ]]
}

@test "session_file: handles command names with hyphens" {
    run session_file "review-code-12345-1234567890"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/review-code/"* ]]
}

# =============================================================================
# session_init tests
# =============================================================================

@test "session_init: creates session file" {
    run session_init "test-cmd" '{"status":"pending"}'
    [ "$status" -eq 0 ]

    # Should output session ID
    [[ "$output" == test-cmd-*-* ]]

    # Extract session ID and verify file exists
    session_id="$output"
    session_path=$(session_file "$session_id")
    [ -f "$session_path" ]
}

@test "session_init: stores initial data as JSON" {
    session_id=$(session_init "test-cmd" '{"status":"pending","foo":"bar"}')
    [ "$?" -eq 0 ]

    session_path=$(session_file "$session_id")
    content=$(cat "$session_path")

    # Should contain the initial data
    echo "$content" | jq -e '.status == "pending"' >/dev/null
    echo "$content" | jq -e '.foo == "bar"' >/dev/null
}

@test "session_init: creates command directory if needed" {
    [ ! -d "$SESSION_DIR/new-cmd" ]

    session_id=$(session_init "new-cmd" '{"test":true}')
    [ "$?" -eq 0 ]

    [ -d "$SESSION_DIR/new-cmd" ]
}

@test "session_init: generates unique session IDs" {
    id1=$(session_init "test-cmd" '{}')
    sleep 1  # Ensure different timestamp
    id2=$(session_init "test-cmd" '{}')

    [ "$id1" != "$id2" ]
}

@test "session_init: rejects invalid command names" {
    run session_init "bad/cmd" '{}'
    [ "$status" -eq 1 ]
}

# =============================================================================
# session_get_all tests
# =============================================================================

@test "session_get_all: retrieves session data" {
    session_id=$(session_init "test-cmd" '{"status":"ready","data":"test"}')

    run session_get_all "$session_id"
    [ "$status" -eq 0 ]

    echo "$output" | jq -e '.status == "ready"' >/dev/null
    echo "$output" | jq -e '.data == "test"' >/dev/null
}

@test "session_get_all: fails for non-existent session" {
    run session_get_all "nonexistent-123-456"
    [ "$status" -eq 1 ]
}

# =============================================================================
# session_set tests
# =============================================================================

@test "session_set: updates existing field" {
    session_id=$(session_init "test-cmd" '{"status":"pending"}')

    session_set "$session_id" "status" "ready"

    data=$(session_get_all "$session_id")
    echo "$data" | jq -e '.status == "ready"' >/dev/null
}

@test "session_set: adds new field" {
    session_id=$(session_init "test-cmd" '{"status":"pending"}')

    session_set "$session_id" "new_field" "new_value"

    data=$(session_get_all "$session_id")
    echo "$data" | jq -e '.new_field == "new_value"' >/dev/null
}

@test "session_set: fails for non-existent session" {
    run session_set "nonexistent-123-456" "field" "value"
    [ "$status" -eq 1 ]
}

# =============================================================================
# session_get tests
# =============================================================================

@test "session_get: retrieves field value" {
    session_id=$(session_init "test-cmd" '{"status":"ready","count":42}')

    run session_get "$session_id" ".status"
    [ "$status" -eq 0 ]
    [ "$output" = "ready" ]
}

@test "session_get: retrieves numeric field" {
    session_id=$(session_init "test-cmd" '{"count":42}')

    run session_get "$session_id" ".count"
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "session_get: returns null for missing field" {
    session_id=$(session_init "test-cmd" '{"status":"ready"}')

    run session_get "$session_id" ".nonexistent"
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

# =============================================================================
# session_cleanup tests
# =============================================================================

@test "session_cleanup: removes specific session" {
    session_id=$(session_init "test-cmd" '{"status":"done"}')
    session_path=$(session_file "$session_id")

    [ -f "$session_path" ]

    session_cleanup "$session_id"

    [ ! -f "$session_path" ]
}

@test "session_cleanup: leaves directory (doesn't auto-remove)" {
    session_id=$(session_init "cleanup-test" '{"test":true}')

    [ -d "$SESSION_DIR/cleanup-test" ]

    session_cleanup "$session_id"

    # Directory remains (not auto-removed when empty)
    [ -d "$SESSION_DIR/cleanup-test" ]
}

@test "session_cleanup: preserves other sessions" {
    id1=$(session_init "multi-test" '{"id":1}')
    sleep 1
    id2=$(session_init "multi-test" '{"id":2}')

    session_cleanup "$id1"

    # Directory should still exist
    [ -d "$SESSION_DIR/multi-test" ]

    # id2's session should still exist
    path2=$(session_file "$id2")
    [ -f "$path2" ]
}

# =============================================================================
# session_cleanup_old tests
# =============================================================================

@test "session_cleanup_old: removes old sessions" {
    # Create an old session by creating the file and touching it to make it old
    old_id="test-cmd-12345-1000000000"
    mkdir -p "$SESSION_DIR/test-cmd"
    echo '{"status":"old"}' > "$SESSION_DIR/test-cmd/$old_id.json"
    # Touch to make it 2 hours old (120 minutes)
    touch -t $(date -v-2H +%Y%m%d%H%M) "$SESSION_DIR/test-cmd/$old_id.json" 2>/dev/null || \
        touch -d '2 hours ago' "$SESSION_DIR/test-cmd/$old_id.json" 2>/dev/null || \
        skip "Cannot set file timestamp"

    # Create a new session
    new_id=$(session_init "test-cmd" '{"status":"new"}')

    # Clean up old sessions (no args = uses default 60 minutes)
    session_cleanup_old

    # Old session should be gone
    [ ! -f "$SESSION_DIR/test-cmd/$old_id.json" ]

    # New session should still exist
    new_path=$(session_file "$new_id")
    [ -f "$new_path" ]
}

@test "session_cleanup_old: cleans specific command" {
    # Create old sessions for different commands
    mkdir -p "$SESSION_DIR/cmd1" "$SESSION_DIR/cmd2"
    echo '{"test":1}' > "$SESSION_DIR/cmd1/cmd1-123-1000000000.json"
    echo '{"test":2}' > "$SESSION_DIR/cmd2/cmd2-456-1000000000.json"

    # Make them old
    touch -t $(date -v-2H +%Y%m%d%H%M) "$SESSION_DIR/cmd1/cmd1-123-1000000000.json" 2>/dev/null || \
        touch -d '2 hours ago' "$SESSION_DIR/cmd1/cmd1-123-1000000000.json" 2>/dev/null || \
        skip "Cannot set file timestamp"
    touch -t $(date -v-2H +%Y%m%d%H%M) "$SESSION_DIR/cmd2/cmd2-456-1000000000.json" 2>/dev/null || \
        touch -d '2 hours ago' "$SESSION_DIR/cmd2/cmd2-456-1000000000.json" 2>/dev/null || \
        skip "Cannot set file timestamp"

    # Clean only cmd1
    session_cleanup_old "cmd1"

    # cmd1's old session should be gone
    [ ! -f "$SESSION_DIR/cmd1/cmd1-123-1000000000.json" ]

    # cmd2's old session should still exist (wasn't cleaned)
    [ -f "$SESSION_DIR/cmd2/cmd2-456-1000000000.json" ]
}

# =============================================================================
# session_list tests
# =============================================================================

@test "session_list: lists sessions for command" {
    id1=$(session_init "list-test" '{"id":1}')
    sleep 1
    id2=$(session_init "list-test" '{"id":2}')

    run session_list "list-test"
    [ "$status" -eq 0 ]

    # Should return JSON array
    echo "$output" | jq -e 'type == "array"' >/dev/null
}

@test "session_list: returns empty array for command with no sessions" {
    run session_list "nonexistent-cmd"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

# =============================================================================
# Security tests
# =============================================================================

@test "security: session_file prevents directory traversal via session ID" {
    run session_file "../../etc-123-456"
    [ "$status" -eq 1 ]
}

@test "security: session_file prevents absolute paths" {
    run session_file "/etc/passwd-123-456"
    [ "$status" -eq 1 ]
}

@test "security: session_init rejects malicious command names" {
    run session_init "../../../tmp/evil" '{}'
    [ "$status" -eq 1 ]
}

@test "security: session_cleanup rejects malicious session IDs" {
    # Create a legitimate session
    session_id=$(session_init "test-cmd" '{}')

    # Try to cleanup with malicious ID
    run session_cleanup "../../etc/passwd"
    [ "$status" -eq 1 ]

    # Original session should still exist
    path=$(session_file "$session_id")
    [ -f "$path" ]
}

# =============================================================================
# Integration tests
# =============================================================================

@test "integration: full session lifecycle" {
    # Create session
    session_id=$(session_init "workflow-test" '{"status":"pending","step":1}')
    [ "$?" -eq 0 ]

    # Update status
    session_set "$session_id" "status" "processing"
    session_set "$session_id" "step" "2"

    # Read back
    status=$(session_get "$session_id" ".status")
    [ "$status" = "processing" ]

    step=$(session_get "$session_id" ".step")
    [ "$step" = "2" ]

    # Get all data
    data=$(session_get_all "$session_id")
    echo "$data" | jq -e '.status == "processing"' >/dev/null
    echo "$data" | jq -e '.step == "2"' >/dev/null

    # Cleanup
    session_cleanup "$session_id"

    path=$(session_file "$session_id")
    [ ! -f "$path" ]
}

@test "integration: multiple concurrent sessions" {
    id1=$(session_init "test-cmd" '{"worker":1}')
    sleep 1
    id2=$(session_init "test-cmd" '{"worker":2}')
    sleep 1
    id3=$(session_init "other-cmd" '{"worker":3}')

    # All should be different
    [ "$id1" != "$id2" ]
    [ "$id2" != "$id3" ]

    # Update them independently
    session_set "$id1" "status" "done"
    session_set "$id2" "status" "pending"
    session_set "$id3" "status" "error"

    # Verify independence
    [ "$(session_get "$id1" ".status")" = "done" ]
    [ "$(session_get "$id2" ".status")" = "pending" ]
    [ "$(session_get "$id3" ".status")" = "error" ]

    # Cleanup one shouldn't affect others
    session_cleanup "$id1"

    path2=$(session_file "$id2")
    path3=$(session_file "$id3")
    [ -f "$path2" ]
    [ -f "$path3" ]
}
