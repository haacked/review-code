#!/usr/bin/env bats
# Tests for clear-marker.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/clear-marker.sh"
    export SCRIPT

    # Isolated marker directory per test
    MARKER_DIR=$(mktemp -d)
    export REVIEW_CODE_MARKER_DIR="$MARKER_DIR"
    MARKER_FILE="$MARKER_DIR/.pending-clear"
    export MARKER_FILE
}

teardown() {
    rm -rf "$MARKER_DIR"
}

# Touch with a specific epoch mtime; tries BSD then GNU syntax.
set_mtime() {
    local file="$1"
    local epoch="$2"
    # BSD: -t [[CC]YY]MMDDhhmm[.SS]
    if touch -t "$(date -r "$epoch" +%Y%m%d%H%M.%S 2> /dev/null)" "$file" 2> /dev/null; then
        return 0
    fi
    # GNU: -d @epoch
    touch -d "@$epoch" "$file"
}

# =============================================================================
# Subcommand validation
# =============================================================================

@test "clear-marker.sh: rejects missing subcommand" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown subcommand"* ]]
}

@test "clear-marker.sh: rejects unknown subcommand" {
    run "$SCRIPT" wat
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown subcommand"* ]]
}

# =============================================================================
# set subcommand
# =============================================================================

@test "clear-marker.sh set: creates marker file" {
    run "$SCRIPT" set
    [ "$status" -eq 0 ]
    [ -f "$MARKER_FILE" ]
}

@test "clear-marker.sh set: creates marker dir if missing" {
    rm -rf "$MARKER_DIR"
    run "$SCRIPT" set
    [ "$status" -eq 0 ]
    [ -f "$MARKER_FILE" ]
}

@test "clear-marker.sh set: refreshes marker mtime on repeat call" {
    "$SCRIPT" set
    set_mtime "$MARKER_FILE" 1000000000
    run "$SCRIPT" set
    [ "$status" -eq 0 ]

    local mtime now
    mtime=$(stat -f %m "$MARKER_FILE" 2> /dev/null || stat -c %Y "$MARKER_FILE")
    now=$(date +%s)
    # New mtime should be close to "now", not the ancient one.
    [ $((now - mtime)) -lt 10 ]
}

# =============================================================================
# check subcommand
# =============================================================================

@test "clear-marker.sh check: prints nothing when no marker exists" {
    run "$SCRIPT" check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "clear-marker.sh check: prints 'skip' for a fresh marker" {
    "$SCRIPT" set
    run "$SCRIPT" check
    [ "$status" -eq 0 ]
    [ "$output" = "skip" ]
}

@test "clear-marker.sh check: consumes marker on success" {
    "$SCRIPT" set
    "$SCRIPT" check
    [ ! -f "$MARKER_FILE" ]
}

@test "clear-marker.sh check: one set satisfies only one check" {
    "$SCRIPT" set
    run "$SCRIPT" check
    [ "$output" = "skip" ]

    run "$SCRIPT" check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "clear-marker.sh check: does not skip for an expired marker" {
    "$SCRIPT" set
    # TTL is 600s — set mtime to 700s ago.
    set_mtime "$MARKER_FILE" "$(($(date +%s) - 700))"

    run "$SCRIPT" check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$MARKER_FILE" ]
}

@test "clear-marker.sh check: skips for a marker just inside TTL" {
    "$SCRIPT" set
    # 500s old — well within the 600s TTL.
    set_mtime "$MARKER_FILE" "$(($(date +%s) - 500))"

    run "$SCRIPT" check
    [ "$status" -eq 0 ]
    [ "$output" = "skip" ]
}
