#!/usr/bin/env bats
# Tests for manage-session-hook.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/manage-session-hook.sh"
    export SCRIPT

    TMPDIR_TEST=$(mktemp -d)
    export CLAUDE_SETTINGS_FILE="$TMPDIR_TEST/settings.json"
    export REVIEW_CODE_HOOK_COMMAND="/test/path/session-clear-hook.sh"
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

# =============================================================================
# Subcommand validation
# =============================================================================

@test "manage-session-hook.sh: rejects missing subcommand" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown subcommand"* ]]
}

@test "manage-session-hook.sh: rejects unknown subcommand" {
    run "$SCRIPT" reset
    [ "$status" -eq 1 ]
}

# =============================================================================
# install: starting from no file
# =============================================================================

@test "install: creates settings.json when missing" {
    run "$SCRIPT" install
    [ "$status" -eq 0 ]
    [ -f "$CLAUDE_SETTINGS_FILE" ]
}

@test "install: writes SessionStart hook with matcher 'startup|clear'" {
    "$SCRIPT" install
    local matcher
    matcher=$(jq -r '.hooks.SessionStart[0].matcher' "$CLAUDE_SETTINGS_FILE")
    [ "$matcher" = "startup|clear" ]
}

@test "install: writes our command into the hook entry" {
    "$SCRIPT" install
    local cmd
    cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    [ "$cmd" = "/test/path/session-clear-hook.sh" ]
}

# =============================================================================
# install: idempotency
# =============================================================================

@test "install: repeated runs do not duplicate the entry" {
    "$SCRIPT" install
    "$SCRIPT" install
    "$SCRIPT" install
    local count
    count=$(jq '.hooks.SessionStart | length' "$CLAUDE_SETTINGS_FILE")
    [ "$count" = "1" ]
}

# =============================================================================
# install: preserves unrelated content
# =============================================================================

@test "install: preserves top-level keys" {
    echo '{"theme": "dark", "model": "sonnet"}' > "$CLAUDE_SETTINGS_FILE"
    "$SCRIPT" install

    [ "$(jq -r '.theme' "$CLAUDE_SETTINGS_FILE")" = "dark" ]
    [ "$(jq -r '.model' "$CLAUDE_SETTINGS_FILE")" = "sonnet" ]
}

@test "install: preserves unrelated SessionStart entries" {
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "other-script"}]}
    ]
  }
}
JSON
    "$SCRIPT" install

    local count other
    count=$(jq '.hooks.SessionStart | length' "$CLAUDE_SETTINGS_FILE")
    other=$(jq -r '.hooks.SessionStart[] | select(.matcher=="startup") | .hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    [ "$count" = "2" ]
    [ "$other" = "other-script" ]
}

@test "install: preserves unrelated hook types" {
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/some/safety.sh"}]}]
  }
}
JSON
    "$SCRIPT" install

    local pre
    pre=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    [ "$pre" = "/some/safety.sh" ]
}

# =============================================================================
# uninstall
# =============================================================================

@test "uninstall: removes our entry" {
    "$SCRIPT" install
    "$SCRIPT" uninstall

    local has_ours
    has_ours=$(jq '[.hooks.SessionStart // [] | .[] | .hooks[]? | select(.command=="/test/path/session-clear-hook.sh")] | length' "$CLAUDE_SETTINGS_FILE")
    [ "$has_ours" = "0" ]
}

@test "uninstall: preserves unrelated SessionStart entries" {
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "other-script"}]}
    ]
  }
}
JSON
    "$SCRIPT" install
    "$SCRIPT" uninstall

    local count other
    count=$(jq '.hooks.SessionStart | length' "$CLAUDE_SETTINGS_FILE")
    other=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    [ "$count" = "1" ]
    [ "$other" = "other-script" ]
}

@test "uninstall: drops SessionStart key when no entries remain" {
    "$SCRIPT" install
    "$SCRIPT" uninstall

    local has_key
    has_key=$(jq 'has("hooks")' "$CLAUDE_SETTINGS_FILE")
    [ "$has_key" = "false" ]
}

@test "uninstall: is a no-op when our hook isn't installed" {
    echo '{"theme": "dark"}' > "$CLAUDE_SETTINGS_FILE"
    "$SCRIPT" uninstall

    [ "$(jq -r '.theme' "$CLAUDE_SETTINGS_FILE")" = "dark" ]
}

@test "install: replaces a legacy review-code entry (different script name in same dir)" {
    # Simulate a previous install that registered the old clear-marker.sh path.
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "clear",
        "hooks": [
          {"type": "command", "command": "/legacy/skills/review-code/scripts/clear-marker.sh set"}
        ]
      }
    ]
  }
}
JSON
    # Match by substring "/skills/review-code/scripts/" so the legacy entry is recognized.
    REVIEW_CODE_HOOK_PATH_MARKER="/skills/review-code/scripts/" "$SCRIPT" install

    # Legacy entry should be gone; new entry (the test command) should be present.
    local legacy current total
    legacy=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command == "/legacy/skills/review-code/scripts/clear-marker.sh set")] | length' "$CLAUDE_SETTINGS_FILE")
    current=$(jq -r '.hooks.SessionStart[].hooks[].command' "$CLAUDE_SETTINGS_FILE")
    total=$(jq '[.hooks.SessionStart[]?.hooks[]?] | length' "$CLAUDE_SETTINGS_FILE")
    [ "$legacy" = "0" ]
    [ "$current" = "/test/path/session-clear-hook.sh" ]
    [ "$total" = "1" ]
}

@test "uninstall: only removes our command, not the whole block, when block has other hooks" {
    cat > "$CLAUDE_SETTINGS_FILE" <<JSON
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "clear",
        "hooks": [
          {"type": "command", "command": "their-script"},
          {"type": "command", "command": "/test/path/session-clear-hook.sh"}
        ]
      }
    ]
  }
}
JSON
    "$SCRIPT" uninstall

    local their count
    their=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    count=$(jq '.hooks.SessionStart[0].hooks | length' "$CLAUDE_SETTINGS_FILE")
    [ "$their" = "their-script" ]
    [ "$count" = "1" ]
}
