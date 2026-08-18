#!/usr/bin/env bats
# Tests for skills/review-code/scripts/review-status-handler.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    HANDLER_SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/review-status-handler.sh"
    export HANDLER_SCRIPT
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "review-status-handler: has correct shebang" {
    run bash -c "head -1 '$HANDLER_SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: uses set -euo pipefail" {
    run bash -c "head -5 '$HANDLER_SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: sources session-manager.sh" {
    run bash -c "grep -q 'source.*session-manager.sh' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Action handling tests
# =============================================================================

@test "review-status-handler: supports init action" {
    run bash -c "grep -q '\"init\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-status action" {
    run bash -c "grep -q '\"get-status\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-ready-data action" {
    run bash -c "grep -q '\"get-ready-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-error-data action" {
    run bash -c "grep -q '\"get-error-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-ambiguous-data action" {
    run bash -c "grep -q '\"get-ambiguous-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-prompt-data action" {
    run bash -c "grep -q '\"get-prompt-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-prompt-pull-data action" {
    run bash -c "grep -q '\"get-prompt-pull-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-find-data action" {
    run bash -c "grep -q '\"get-find-data\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports get-session-file action" {
    run bash -c "grep -q '\"get-session-file\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports cleanup action" {
    run bash -c "grep -q '\"cleanup\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: supports cleanup-old action" {
    run bash -c "grep -q '\"cleanup-old\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: has unknown action handler" {
    run bash -c "grep -q 'Unknown action' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Session ID validation tests
# =============================================================================

@test "review-status-handler: get-status requires session ID" {
    run bash -c "grep -A10 '\"get-status\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-ready-data requires session ID" {
    run bash -c "grep -A10 '\"get-ready-data\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-error-data requires session ID" {
    run bash -c "grep -A10 '\"get-error-data\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-session-file requires session ID" {
    run bash -c "grep -A10 '\"get-session-file\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: cleanup requires session ID" {
    run bash -c "grep -A10 '\"cleanup\")' '$HANDLER_SCRIPT' | grep -q 'Session ID required'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Status validation tests
# =============================================================================

@test "review-status-handler: get-error-data validates status is error" {
    run bash -c "grep -A15 '\"get-error-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*error'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-ready-data validates status is ready" {
    run bash -c "grep -A15 '\"get-ready-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*ready'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-ambiguous-data validates status is ambiguous" {
    run bash -c "grep -A15 '\"get-ambiguous-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*ambiguous'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-prompt-data validates status is prompt" {
    run bash -c "grep -A15 '\"get-prompt-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*prompt'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-find-data validates status is find" {
    run bash -c "grep -A15 '\"get-find-data\")' '$HANDLER_SCRIPT' | grep -q 'Status is not.*find'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Session manager integration tests
# =============================================================================

@test "review-status-handler: init uses session_init" {
    run bash -c "grep -A25 '\"init\")' '$HANDLER_SCRIPT' | grep -q 'session_init'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-status uses session_get" {
    run bash -c "grep -A10 '\"get-status\")' '$HANDLER_SCRIPT' | grep -q 'session_get'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: cleanup uses session_cleanup" {
    run bash -c "grep -A10 '\"cleanup\")' '$HANDLER_SCRIPT' | grep -q 'session_cleanup'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: cleanup-old uses session_cleanup_old" {
    run bash -c "grep -A5 '\"cleanup-old\")' '$HANDLER_SCRIPT' | grep -q 'session_cleanup_old'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-session-file uses session_file" {
    run bash -c "grep -A10 '\"get-session-file\")' '$HANDLER_SCRIPT' | grep -q 'session_file'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Orchestrator discovery tests
# =============================================================================

@test "review-status-handler: has find_orchestrator function" {
    run bash -c "grep -q '^find_orchestrator()' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: find_orchestrator checks multiple locations" {
    run bash -c "grep -A15 '^find_orchestrator()' '$HANDLER_SCRIPT' | grep -c 'review-orchestrator.sh'"
    [ "$output" -ge 3 ]
}

@test "review-status-handler: find_orchestrator errors if not found" {
    run bash -c "grep -A15 '^find_orchestrator()' '$HANDLER_SCRIPT' | grep -q 'Cannot find review-orchestrator.sh'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Output format tests
# =============================================================================

@test "review-status-handler: get-ambiguous-data outputs JSON" {
    run bash -c "grep -A20 '\"get-ambiguous-data\")' '$HANDLER_SCRIPT' | grep -q 'jq'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: get-prompt-data outputs JSON" {
    run bash -c "grep -A20 '\"get-prompt-data\")' '$HANDLER_SCRIPT' | grep -q 'jq'"
    [ "$status" -eq 0 ]
}

@test "review-status-handler: cleanup outputs confirmation message" {
    run bash -c "grep -A10 '\"cleanup\")' '$HANDLER_SCRIPT' | grep -q 'Session cleaned up'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# get-review-fields: the narrow accessor that keeps the diff out of context
# =============================================================================

# A session in the layout session-manager.sh uses, carrying every field the
# accessor must exclude as well as the ones it must return.
make_session() {
    export CLAUDE_SESSION_DIR="$BATS_TEST_TMPDIR/sessions"
    local cmd_dir="$CLAUDE_SESSION_DIR/review-code"
    mkdir -p "$cmd_dir"
    local id="review-code-4242-1234567890"
    jq -n '{
        status: "ready",
        mode: "pr",
        diff_tokens: 938,
        diff_path: "/tmp/artifacts/diff.patch",
        artifacts_dir: "/tmp/artifacts",
        languages: {has_frontend: true},
        file_info: {file_path: "/tmp/pr-1.md", file_exists: false},
        file_metadata: {modified_files: [{path: "a.ts"}]},
        display_summary: "Reviewing PR #1",
        summary: {repository: "org/repo", mode: "pr"},
        git: {working_dir: "/tmp/wt"},
        file_ref: "abc123",
        chunk_metadata: null,
        append: true,
        reviewer_username: "me",
        is_own_pr: false,
        diff: "diff --git a/a.ts b/a.ts\n+SECRET_DIFF_BYTES",
        review_context: "LARGE_CONTEXT_FILE_BODY",
        commit_messages: "msg",
        pr: {
            number: 1, title: "T", author: "a", url: "u", base: "main", head: "f",
            head_sha: "deadbeef",
            body: "LARGE_PR_BODY_TEXT",
            comments: {conversation: [{author: "x", body: "LARGE_COMMENT_TEXT"}], reviews: [], inline: []}
        }
    }' > "$cmd_dir/$id.json"
    echo "$id"
}

fields_of() {
    CLAUDE_SESSION_DIR="$BATS_TEST_TMPDIR/sessions" "$HANDLER_SCRIPT" get-review-fields "$1"
}

@test "review-status-handler: supports get-review-fields action" {
    run bash -c "grep -q '\"get-review-fields\")' '$HANDLER_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "get-review-fields: requires a session ID" {
    run "$HANDLER_SCRIPT" get-review-fields
    [ "$status" -ne 0 ]
}

@test "get-review-fields: emits valid JSON" {
    local id; id=$(make_session)
    run fields_of "$id"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e . > /dev/null
}

@test "get-review-fields: returns the orchestration fields" {
    local id; id=$(make_session)
    run fields_of "$id"
    [ "$(echo "$output" | jq -r '.mode')" = "pr" ]
    [ "$(echo "$output" | jq -r '.diff_path')" = "/tmp/artifacts/diff.patch" ]
    [ "$(echo "$output" | jq -r '.artifacts_dir')" = "/tmp/artifacts" ]
    [ "$(echo "$output" | jq -r '.file_info.file_path')" = "/tmp/pr-1.md" ]
    [ "$(echo "$output" | jq -r '.display_summary')" = "Reviewing PR #1" ]
    [ "$(echo "$output" | jq -r '.file_ref')" = "abc123" ]
    [ "$(echo "$output" | jq -r '.git.working_dir')" = "/tmp/wt" ]
    [ "$(echo "$output" | jq -r '.languages.has_frontend')" = "true" ]
}

@test "get-review-fields: preserves mode flags" {
    local id; id=$(make_session)
    run fields_of "$id"
    [ "$(echo "$output" | jq -r '.append')" = "true" ]
}

@test "get-review-fields: returns PR identity without the PR body" {
    local id; id=$(make_session)
    run fields_of "$id"
    [ "$(echo "$output" | jq -r '.pr.number')" = "1" ]
    [ "$(echo "$output" | jq -r '.pr.head_sha')" = "deadbeef" ]
    [ "$(echo "$output" | jq -r '.pr.body // "absent"')" = "absent" ]
}

# The four exclusions below are the entire point of this accessor: each is a
# large payload already written to a file for the agents, and returning it here
# would put it back in the orchestrator's context for the rest of the run.

@test "get-review-fields: never returns the diff" {
    local id; id=$(make_session)
    run fields_of "$id"
    [ "$(echo "$output" | jq -r 'has("diff")')" = "false" ]
    ! echo "$output" | grep -q "SECRET_DIFF_BYTES"
}

@test "get-review-fields: never returns review_context" {
    local id; id=$(make_session)
    run fields_of "$id"
    [ "$(echo "$output" | jq -r 'has("review_context")')" = "false" ]
    ! echo "$output" | grep -q "LARGE_CONTEXT_FILE_BODY"
}

@test "get-review-fields: never returns the PR body" {
    local id; id=$(make_session)
    run fields_of "$id"
    ! echo "$output" | grep -q "LARGE_PR_BODY_TEXT"
}

@test "get-review-fields: never returns PR comments" {
    local id; id=$(make_session)
    run fields_of "$id"
    [ "$(echo "$output" | jq -r '.pr | has("comments")')" = "false" ]
    ! echo "$output" | grep -q "LARGE_COMMENT_TEXT"
}

@test "get-review-fields: output stays small relative to the session file" {
    local id; id=$(make_session)
    run fields_of "$id"
    local session_size fields_size
    session_size=$(wc -c < "$BATS_TEST_TMPDIR/sessions/review-code/$id.json")
    fields_size=${#output}
    [ "$fields_size" -lt "$session_size" ]
}

@test "get-review-fields: rejects a nonexistent session ID" {
    export CLAUDE_SESSION_DIR="$BATS_TEST_TMPDIR/sessions"
    mkdir -p "$CLAUDE_SESSION_DIR/review-code"
    run fields_of "review-code-0-0"
    [ "$status" -ne 0 ]
}
