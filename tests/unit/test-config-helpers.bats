#!/usr/bin/env bats
# Tests for lib/helpers/config-helpers.sh

setup() {
    # Get paths
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/helpers/config-helpers.sh"

    # Source the script
    source "$PROJECT_ROOT/skills/review-code/scripts/helpers/error-helpers.sh"
    source "$SCRIPT"

    # Create temporary directory for test configs
    TEST_TEMP_DIR="$(mktemp -d)"
}

teardown() {
    # Clean up temp directory
    [ -d "$TEST_TEMP_DIR" ] && rm -rf "$TEST_TEMP_DIR"
}

# === Basic Functionality ===

@test "load_config_safely: loads valid config file" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
CONTEXT_PATH="/tmp/context"
DIFF_CONTEXT_LINES="3"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    [ "$REVIEW_ROOT_PATH" = "/tmp/reviews" ]
    [ "$CONTEXT_PATH" = "/tmp/context" ]
    [ "$DIFF_CONTEXT_LINES" = "3" ]
}

@test "load_config_safely: returns 0 if config file doesn't exist" {
    run load_config_safely "$TEST_TEMP_DIR/nonexistent.env"
    [ "$status" -eq 0 ]
}

@test "load_config_safely: handles empty config file" {
    touch "$TEST_TEMP_DIR/empty.env"

    run load_config_safely "$TEST_TEMP_DIR/empty.env"
    [ "$status" -eq 0 ]
}

@test "load_config_safely: ignores comments" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
# This is a comment
REVIEW_ROOT_PATH="/tmp/reviews"
# Another comment
CONTEXT_PATH="/tmp/context"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    [ "$REVIEW_ROOT_PATH" = "/tmp/reviews" ]
    [ "$CONTEXT_PATH" = "/tmp/context" ]
}

@test "load_config_safely: ignores empty lines" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'

REVIEW_ROOT_PATH="/tmp/reviews"

CONTEXT_PATH="/tmp/context"

EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    [ "$REVIEW_ROOT_PATH" = "/tmp/reviews" ]
    [ "$CONTEXT_PATH" = "/tmp/context" ]
}

# === Quote Handling ===

@test "load_config_safely: removes double quotes from values" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$REVIEW_ROOT_PATH" = "/tmp/reviews" ]
}

@test "load_config_safely: removes single quotes from values" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH='/tmp/reviews'
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$REVIEW_ROOT_PATH" = "/tmp/reviews" ]
}

@test "load_config_safely: handles values without quotes" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH=/tmp/reviews
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$REVIEW_ROOT_PATH" = "/tmp/reviews" ]
}

# === Security - Arbitrary Code Execution Prevention ===

@test "load_config_safely: prevents code execution via backticks" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
`touch /tmp/test-exploit-backtick`
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    # File should NOT be created
    [ ! -f "/tmp/test-exploit-backtick" ]
}

@test "load_config_safely: prevents code execution via command substitution" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
$(touch /tmp/test-exploit-dollar)
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    # File should NOT be created
    [ ! -f "/tmp/test-exploit-dollar" ]
}

@test "load_config_safely: prevents code execution in value" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="$(rm -rf /tmp/important)"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    # Value should be literal string, not executed
    [ "$REVIEW_ROOT_PATH" = '$(rm -rf /tmp/important)' ]
}

@test "load_config_safely: ignores malicious key names" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
rm -rf /important=bad
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    # Valid key should be loaded
    [ "$REVIEW_ROOT_PATH" = "/tmp/reviews" ]
}

# === Security - File Permission Checks ===

@test "load_config_safely: fails if config is world-writable" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
EOF
    chmod 666 "$TEST_TEMP_DIR/config.env"

    run load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$status" -eq 1 ]
    [[ "$output" == *"world-writable"* ]]
}

@test "load_config_safely: succeeds with user-only permissions" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
EOF
    chmod 600 "$TEST_TEMP_DIR/config.env"

    run load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$status" -eq 0 ]
}

@test "load_config_safely: succeeds with user+group read permissions" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
EOF
    chmod 640 "$TEST_TEMP_DIR/config.env"

    run load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$status" -eq 0 ]
}

# === Whitelist Validation ===

@test "load_config_safely: ignores unknown config keys" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
UNKNOWN_KEY="value"
ANOTHER_UNKNOWN="value"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    # Known key should be loaded
    [ "$REVIEW_ROOT_PATH" = "/tmp/reviews" ]

    # Unknown keys should NOT be set
    [ -z "${UNKNOWN_KEY:-}" ]
    [ -z "${ANOTHER_UNKNOWN:-}" ]
}

@test "load_config_safely: validates key format (rejects lowercase)" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
review_root_path="/tmp/reviews"
REVIEW_ROOT_PATH="/tmp/correct"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    # Only uppercase key should be loaded
    [ "$REVIEW_ROOT_PATH" = "/tmp/correct" ]
}

@test "load_config_safely: validates key format (rejects special chars)" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW-ROOT-PATH="/tmp/reviews"
REVIEW_ROOT_PATH="/tmp/correct"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    # Only valid key should be loaded
    [ "$REVIEW_ROOT_PATH" = "/tmp/correct" ]
}

@test "load_config_safely: allows all supported config keys" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
CONTEXT_PATH="/tmp/context"
DIFF_CONTEXT_LINES="5"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"

    [ "$REVIEW_ROOT_PATH" = "/tmp/reviews" ]
    [ "$CONTEXT_PATH" = "/tmp/context" ]
    [ "$DIFF_CONTEXT_LINES" = "5" ]
}

# === Edge Cases ===

@test "load_config_safely: handles values with spaces" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/my reviews with spaces"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$REVIEW_ROOT_PATH" = "/tmp/my reviews with spaces" ]
}

@test "load_config_safely: handles values with equals signs" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/path=with=equals"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$REVIEW_ROOT_PATH" = "/tmp/path=with=equals" ]
}

@test "load_config_safely: handles empty values" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH=
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$REVIEW_ROOT_PATH" = "" ]
}

@test "load_config_safely: last value wins for duplicate keys" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/first"
REVIEW_ROOT_PATH="/tmp/second"
EOF

    load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$REVIEW_ROOT_PATH" = "/tmp/second" ]
}

# =============================================================================
# get_review_root tests
# =============================================================================

@test "get_review_root: returns default when no config file exists" {
    # Use a temp HOME with no config files
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME"

    HOME="$FAKE_HOME" run get_review_root

    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_HOME/dev/ai/reviews" ]
}

@test "get_review_root: uses primary config path when it exists" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME/.claude/skills/review-code"

    cat > "$FAKE_HOME/.claude/skills/review-code/.env" << 'EOF'
REVIEW_ROOT_PATH="/custom/review/path"
EOF
    chmod 600 "$FAKE_HOME/.claude/skills/review-code/.env"

    HOME="$FAKE_HOME" run get_review_root

    [ "$status" -eq 0 ]
    [ "$output" = "/custom/review/path" ]
}

@test "get_review_root: uses fallback config path when primary doesn't exist" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME/.claude"

    cat > "$FAKE_HOME/.claude/review-code.env" << 'EOF'
REVIEW_ROOT_PATH="/fallback/review/path"
EOF
    chmod 600 "$FAKE_HOME/.claude/review-code.env"

    HOME="$FAKE_HOME" run get_review_root

    [ "$status" -eq 0 ]
    [ "$output" = "/fallback/review/path" ]
}

@test "get_review_root: primary config takes precedence over fallback" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME/.claude/skills/review-code"

    # Create both config files
    cat > "$FAKE_HOME/.claude/skills/review-code/.env" << 'EOF'
REVIEW_ROOT_PATH="/primary/path"
EOF
    chmod 600 "$FAKE_HOME/.claude/skills/review-code/.env"

    cat > "$FAKE_HOME/.claude/review-code.env" << 'EOF'
REVIEW_ROOT_PATH="/fallback/path"
EOF
    chmod 600 "$FAKE_HOME/.claude/review-code.env"

    HOME="$FAKE_HOME" run get_review_root

    [ "$status" -eq 0 ]
    [ "$output" = "/primary/path" ]
}

@test "get_review_root: returns default when config exists but REVIEW_ROOT_PATH not set" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME/.claude/skills/review-code"

    # Create config with different variable
    cat > "$FAKE_HOME/.claude/skills/review-code/.env" << 'EOF'
CONTEXT_PATH="/some/context/path"
EOF
    chmod 600 "$FAKE_HOME/.claude/skills/review-code/.env"

    HOME="$FAKE_HOME" run get_review_root

    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_HOME/dev/ai/reviews" ]
}

@test "get_review_root: handles empty REVIEW_ROOT_PATH by using default" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME/.claude/skills/review-code"

    cat > "$FAKE_HOME/.claude/skills/review-code/.env" << 'EOF'
REVIEW_ROOT_PATH=
EOF
    chmod 600 "$FAKE_HOME/.claude/skills/review-code/.env"

    HOME="$FAKE_HOME" run get_review_root

    [ "$status" -eq 0 ]
    # Empty value should fall back to default via ${REVIEW_ROOT_PATH:-default}
    [ "$output" = "$FAKE_HOME/dev/ai/reviews" ]
}
