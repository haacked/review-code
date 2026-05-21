#!/usr/bin/env bats
# Tests for session-clear-hook.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    HOOK="$PROJECT_ROOT/skills/review-code/scripts/session-clear-hook.sh"
    PR="$PROJECT_ROOT/skills/review-code/scripts/pending-resume.sh"
    CM="$PROJECT_ROOT/skills/review-code/scripts/clear-marker.sh"
    export HOOK PR CM

    MARKER_DIR=$(mktemp -d)
    export REVIEW_CODE_MARKER_DIR="$MARKER_DIR"
}

teardown() {
    rm -rf "$MARKER_DIR"
}

# =============================================================================
# Default path: no pending resume
# =============================================================================

@test "no pending resume: produces no JSON output" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no pending resume: still writes the skip-prompt marker" {
    "$HOOK"
    run "$CM" check
    [ "$output" = "skip" ]
}

# =============================================================================
# Resume path
# =============================================================================

@test "with pending resume: outputs valid JSON" {
    "$PR" set-string "55298 --draft"
    run "$HOOK"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.' > /dev/null
}

@test "with pending resume: targets SessionStart" {
    "$PR" set-string "55298"
    run "$HOOK"
    local hook_event
    hook_event=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')
    [ "$hook_event" = "SessionStart" ]
}

@test "with pending resume: additionalContext mentions the args" {
    "$PR" set-string "55298 --draft"
    run "$HOOK"
    echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "55298 --draft"
}

@test "with pending resume: still writes the skip-prompt marker" {
    "$PR" set-string "55298"
    "$HOOK" > /dev/null
    run "$CM" check
    [ "$output" = "skip" ]
}

@test "with pending resume: consumes the pending file" {
    "$PR" set-string "55298"
    "$HOOK" > /dev/null
    [ ! -f "$MARKER_DIR/.pending-resume" ]
}

@test "with pending resume: empty args still trigger auto-resume" {
    "$PR" set-string ""
    run "$HOOK"
    [ "$status" -eq 0 ]
    # Should output JSON instructing Claude to resume the default review
    echo "$output" | jq -e '.' > /dev/null
    local ctx
    ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    [[ "$ctx" == *"no arguments"* ]]
    [[ "$ctx" == *"/review-code"* ]]
}

@test "with pending resume: file paths in args round-trip" {
    "$PR" set-string '55298 "src/**/*.ts"'
    run "$HOOK"
    local args
    args=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    [[ "$args" == *'src/**/*.ts'* ]]
}

# =============================================================================
# Robustness
# =============================================================================

@test "hook does not fail when marker dir is missing" {
    rm -rf "$MARKER_DIR"
    run "$HOOK"
    [ "$status" -eq 0 ]
}
