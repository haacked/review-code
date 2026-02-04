#!/usr/bin/env bats
# Tests for lib/helpers/config-helpers.sh
#
# Note: The config-helpers module no longer uses config files.
# Paths are now fixed relative to the skill directory:
#   ~/.claude/skills/review-code/
#     context/     - Language, framework, and org context files
#     reviews/     - Review output files (org/repo/pr.md)
#     learnings/   - Learning index

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

# === load_config_safely (Legacy - Now No-Op) ===

@test "load_config_safely: is a no-op that returns 0" {
    # load_config_safely is now a no-op since we no longer use config files
    run load_config_safely "/any/path.env"
    [ "$status" -eq 0 ]
}

@test "load_config_safely: returns 0 for non-existent file" {
    run load_config_safely "$TEST_TEMP_DIR/nonexistent.env"
    [ "$status" -eq 0 ]
}

@test "load_config_safely: returns 0 for any file" {
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
REVIEW_ROOT_PATH="/tmp/reviews"
EOF

    run load_config_safely "$TEST_TEMP_DIR/config.env"
    [ "$status" -eq 0 ]
}

# === get_review_root ===

@test "get_review_root: returns fixed path under skill directory" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME"

    HOME="$FAKE_HOME" run get_review_root

    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_HOME/.claude/skills/review-code/reviews" ]
}

@test "get_review_root: path is consistent across calls" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME"

    local first_result
    local second_result
    first_result=$(HOME="$FAKE_HOME" get_review_root)
    second_result=$(HOME="$FAKE_HOME" get_review_root)

    [ "$first_result" = "$second_result" ]
}

@test "get_review_root: ignores config files (no longer used)" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME/.claude/skills/review-code"

    # Even with a config file present, should use fixed path
    cat > "$FAKE_HOME/.claude/skills/review-code/.env" << 'EOF'
REVIEW_ROOT_PATH="/custom/review/path"
EOF

    HOME="$FAKE_HOME" run get_review_root

    [ "$status" -eq 0 ]
    # Should return fixed path, not config value
    [ "$output" = "$FAKE_HOME/.claude/skills/review-code/reviews" ]
}

# === get_context_path ===

@test "get_context_path: returns fixed path under skill directory" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME"

    HOME="$FAKE_HOME" run get_context_path

    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_HOME/.claude/skills/review-code/context" ]
}

@test "get_context_path: path is consistent across calls" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME"

    local first_result
    local second_result
    first_result=$(HOME="$FAKE_HOME" get_context_path)
    second_result=$(HOME="$FAKE_HOME" get_context_path)

    [ "$first_result" = "$second_result" ]
}

# === get_learnings_dir ===

@test "get_learnings_dir: returns fixed path under skill directory" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME"

    HOME="$FAKE_HOME" run get_learnings_dir

    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_HOME/.claude/skills/review-code/learnings" ]
}

@test "get_learnings_dir: path is consistent across calls" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME"

    local first_result
    local second_result
    first_result=$(HOME="$FAKE_HOME" get_learnings_dir)
    second_result=$(HOME="$FAKE_HOME" get_learnings_dir)

    [ "$first_result" = "$second_result" ]
}

# === Path Consistency Tests ===

@test "all paths are under the same skill directory" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME"

    local review_root context_path learnings_dir
    review_root=$(HOME="$FAKE_HOME" get_review_root)
    context_path=$(HOME="$FAKE_HOME" get_context_path)
    learnings_dir=$(HOME="$FAKE_HOME" get_learnings_dir)

    local skill_dir="$FAKE_HOME/.claude/skills/review-code"

    [[ "$review_root" == "$skill_dir"/* ]]
    [[ "$context_path" == "$skill_dir"/* ]]
    [[ "$learnings_dir" == "$skill_dir"/* ]]
}

@test "paths use different subdirectories" {
    local FAKE_HOME="$TEST_TEMP_DIR/fakehome"
    mkdir -p "$FAKE_HOME"

    local review_root context_path learnings_dir
    review_root=$(HOME="$FAKE_HOME" get_review_root)
    context_path=$(HOME="$FAKE_HOME" get_context_path)
    learnings_dir=$(HOME="$FAKE_HOME" get_learnings_dir)

    # All three should be different
    [ "$review_root" != "$context_path" ]
    [ "$review_root" != "$learnings_dir" ]
    [ "$context_path" != "$learnings_dir" ]
}
