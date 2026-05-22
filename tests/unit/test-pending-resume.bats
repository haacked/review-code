#!/usr/bin/env bats
# Tests for pending-resume.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/pending-resume.sh"
    export SCRIPT

    MARKER_DIR=$(mktemp -d)
    export REVIEW_CODE_MARKER_DIR="$MARKER_DIR"
    FILE="$MARKER_DIR/.pending-resume"
    export FILE
}

teardown() {
    rm -rf "$MARKER_DIR"
}

# Touch with a specific epoch mtime; tries BSD then GNU syntax.
set_mtime() {
    local file="$1"
    local epoch="$2"
    if touch -t "$(date -r "$epoch" +%Y%m%d%H%M.%S 2> /dev/null)" "$file" 2> /dev/null; then
        return 0
    fi
    touch -d "@$epoch" "$file"
}

# =============================================================================
# set / set-string
# =============================================================================

@test "set: stores args joined with spaces" {
    "$SCRIPT" set 55298 --draft
    [ "$(cat "$FILE")" = "55298 --draft" ]
}

@test "set-string: stores the argument verbatim" {
    "$SCRIPT" set-string '55298 "src/**/*.ts"'
    [ "$(cat "$FILE")" = '55298 "src/**/*.ts"' ]
}

@test "set-string: handles an empty string" {
    "$SCRIPT" set-string ""
    [ -f "$FILE" ]
    [ -z "$(cat "$FILE")" ]
}

# =============================================================================
# get / consume / clear
# =============================================================================

@test "get: prints args without deleting" {
    "$SCRIPT" set-string "abc"
    run "$SCRIPT" get
    [ "$output" = "abc" ]
    [ -f "$FILE" ]
}

@test "get: prints nothing when file missing" {
    run "$SCRIPT" get
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "consume: prints args and deletes the file" {
    "$SCRIPT" set-string "abc"
    run "$SCRIPT" consume
    [ "$status" -eq 0 ]
    [ "$output" = "abc" ]
    [ ! -f "$FILE" ]
}

@test "consume: exit 0 with empty output when args were empty" {
    "$SCRIPT" set-string ""
    run "$SCRIPT" consume
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$FILE" ]
}

@test "consume: exit 1 when nothing was pending" {
    run "$SCRIPT" consume
    [ "$status" -eq 1 ]
}

@test "consume: exit 1 when only an expired file remains" {
    "$SCRIPT" set-string "abc"
    set_mtime "$FILE" "$(($(date +%s) - 700))"
    run "$SCRIPT" consume
    [ "$status" -eq 1 ]
}

@test "clear: deletes the file" {
    "$SCRIPT" set-string "abc"
    "$SCRIPT" clear
    [ ! -f "$FILE" ]
}

# =============================================================================
# TTL
# =============================================================================

@test "get: returns nothing once the file has aged past TTL" {
    "$SCRIPT" set-string "abc"
    set_mtime "$FILE" "$(($(date +%s) - 700))"
    run "$SCRIPT" get
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$FILE" ]
}

@test "get: still returns inside TTL" {
    "$SCRIPT" set-string "abc"
    set_mtime "$FILE" "$(($(date +%s) - 500))"
    run "$SCRIPT" get
    [ "$output" = "abc" ]
}

# =============================================================================
# Subcommand validation
# =============================================================================

@test "rejects missing subcommand" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "rejects unknown subcommand" {
    run "$SCRIPT" wut
    [ "$status" -eq 1 ]
}
