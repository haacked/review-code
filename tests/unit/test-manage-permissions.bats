#!/usr/bin/env bats
# Tests for bin/manage-permissions

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    TEST_TEMP_DIR=$(mktemp -d)
    export HOME="$TEST_TEMP_DIR"
    mkdir -p "$HOME/.claude"

    MANAGE_PERMISSIONS="$PROJECT_ROOT/bin/manage-permissions"
}

teardown() {
    [ -d "$TEST_TEMP_DIR" ] && rm -rf "$TEST_TEMP_DIR"
}

# Helper: create a settings file with specific permissions in the allow array
create_settings() {
    local perms_json="$1"
    cat > "$HOME/.claude/settings.json" << EOF
{"permissions":{"allow":${perms_json},"deny":[],"ask":[]}}
EOF
}

# =============================================================================
# cmd_migrate tests
# =============================================================================

@test "cmd_migrate: removes stale permissions while preserving current ones" {
    create_settings '["Bash(~/.claude/skills/review-code/scripts/*:*)","Read(~/.claude/**)","Bash(SESSION_ID=:*)","Bash(git rev-parse:*)"]'

    run "$MANAGE_PERMISSIONS" migrate
    [ "$status" -eq 0 ]

    # Stale permissions should be gone
    run jq -e '.permissions.allow | index("Bash(SESSION_ID=:*)")' "$HOME/.claude/settings.json"
    [ "$status" -ne 0 ]
    run jq -e '.permissions.allow | index("Bash(git rev-parse:*)")' "$HOME/.claude/settings.json"
    [ "$status" -ne 0 ]

    # Current permissions should remain
    run jq -e '.permissions.allow | index("Bash(~/.claude/skills/review-code/scripts/*:*)")' "$HOME/.claude/settings.json"
    [ "$status" -eq 0 ]
    run jq -e '.permissions.allow | index("Read(~/.claude/**)")' "$HOME/.claude/settings.json"
    [ "$status" -eq 0 ]
}

@test "cmd_migrate: no-op when no stale permissions exist" {
    create_settings '["Bash(~/.claude/skills/review-code/scripts/*:*)","Read(~/.claude/**)"]'

    run "$MANAGE_PERMISSIONS" migrate
    [ "$status" -eq 0 ]
    [[ "$output" == *"No stale permissions to remove"* ]]
}

@test "cmd_migrate: handles all stale permission types" {
    create_settings '["Bash(~/.claude/bin/review-code/*:*)","Bash(SESSION_ID=:*)","Bash(review_data=:*)","Bash(ls -la /tmp/review-code:*)","Bash(git rev-parse:*)"]'

    run "$MANAGE_PERMISSIONS" migrate
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed 5 stale permission(s)"* ]]

    # All stale should be removed
    local remaining
    remaining=$(jq '.permissions.allow | length' "$HOME/.claude/settings.json")
    [ "$remaining" -eq 0 ]
}

@test "cmd_migrate: quiet mode suppresses output when nothing to remove" {
    create_settings '["Bash(~/.claude/skills/review-code/scripts/*:*)"]'

    run "$MANAGE_PERMISSIONS" migrate --quiet
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "cmd_migrate: quiet mode still reports when stale permissions were removed" {
    create_settings '["Bash(SESSION_ID=:*)"]'

    run "$MANAGE_PERMISSIONS" migrate --quiet
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed 1 stale permission(s)"* ]]
}

@test "cmd_migrate: handles empty allow array" {
    create_settings '[]'

    run "$MANAGE_PERMISSIONS" migrate
    [ "$status" -eq 0 ]
    [[ "$output" == *"No stale permissions to remove"* ]]
}

@test "cmd_migrate: handles missing settings file gracefully" {
    # create_settings_if_needed in manage-permissions creates the file if missing,
    # so after running the command, the file should exist and be empty
    rm -f "$HOME/.claude/settings.json"

    run "$MANAGE_PERMISSIONS" migrate
    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude/settings.json" ]
}

# =============================================================================
# cmd_remove with stale cleanup tests
# =============================================================================

@test "cmd_remove: also cleans stale permissions" {
    create_settings '["Bash(~/.claude/skills/review-code/scripts/*:*)","Read(~/.claude/**)","Bash(SESSION_ID=:*)"]'

    # cmd_remove is interactive (prompts), so we pipe 'y' for confirmation
    run bash -c "echo y | '$MANAGE_PERMISSIONS' remove"
    [ "$status" -eq 0 ]

    # Both current and stale should be removed
    local remaining
    remaining=$(jq '.permissions.allow | length' "$HOME/.claude/settings.json")
    [ "$remaining" -eq 0 ]
}

# =============================================================================
# cmd_check tests
# =============================================================================

@test "cmd_check: returns 0 when all required permissions present" {
    create_settings '["Bash(~/.claude/skills/review-code/scripts/*:*)","Read(~/.claude/**)"]'

    run "$MANAGE_PERMISSIONS" check
    [ "$status" -eq 0 ]
}

@test "cmd_check: returns 1 when missing a required permission" {
    create_settings '["Bash(~/.claude/skills/review-code/scripts/*:*)"]'

    run "$MANAGE_PERMISSIONS" check
    [ "$status" -eq 1 ]
}

@test "cmd_check: returns 1 when settings file is missing" {
    rm -f "$HOME/.claude/settings.json"

    # cmd_check is called after create_settings_if_needed, but the new file has
    # an empty allow array, so check should fail
    run "$MANAGE_PERMISSIONS" check
    [ "$status" -eq 1 ]
}

@test "cmd_check: returns 0 with extra unrelated permissions" {
    create_settings '["Bash(~/.claude/skills/review-code/scripts/*:*)","Read(~/.claude/**)","Bash(git status:*)"]'

    run "$MANAGE_PERMISSIONS" check
    [ "$status" -eq 0 ]
}

# =============================================================================
# cmd_list tests
# =============================================================================

@test "cmd_list: outputs all required permissions" {
    create_settings '[]'

    run "$MANAGE_PERMISSIONS" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Bash(~/.claude/skills/review-code/scripts/*:*)"* ]]
    [[ "$output" == *"Read(~/.claude/**)"* ]]
}

@test "cmd_list: outputs one permission per line" {
    create_settings '[]'

    local count
    count=$("$MANAGE_PERMISSIONS" list | wc -l | tr -d ' ')
    [ "$count" -eq 2 ]
}

# =============================================================================
# cmd_status stale detection tests
# =============================================================================

@test "cmd_status: detects git rev-parse as stale" {
    create_settings '["Bash(~/.claude/skills/review-code/scripts/*:*)","Read(~/.claude/**)","Bash(git rev-parse:*)"]'

    run "$MANAGE_PERMISSIONS" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Bash(git rev-parse:*)"* ]]
    [[ "$output" == *"Stale permissions found"* ]]
}
