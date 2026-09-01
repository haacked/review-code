#!/usr/bin/env bats
# Tests for bin/install-codex.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    INSTALLER="$PROJECT_ROOT/bin/install-codex.sh"

    FAKE_HOME=$(mktemp -d)
    ORIG_HOME="$HOME"
    export HOME="$FAKE_HOME"
}

teardown() {
    export HOME="$ORIG_HOME"
    rm -rf "$FAKE_HOME"
}

@test "install-codex.sh: creates the staging dir under ~/.codex" {
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    [ -d "$FAKE_HOME/.codex/.review-code-agents" ]
}

@test "install-codex.sh: creates ~/.codex/agents" {
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    [ -d "$FAKE_HOME/.codex/agents" ]
}

@test "install-codex.sh: renders one TOML per agent under staging" {
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    local count
    count=$(find "$FAKE_HOME/.codex/.review-code-agents" -name '*.toml' -type f | wc -l | tr -d ' ')
    [ "$count" -eq 14 ]
    [ -f "$FAKE_HOME/.codex/.review-code-agents/code-reviewer-comment.toml" ]
}

@test "install-codex.sh: symlinks every rendered TOML into ~/.codex/agents" {
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    local count
    count=$(find "$FAKE_HOME/.codex/agents" -name '*.toml' -type l | wc -l | tr -d ' ')
    [ "$count" -eq 14 ]
    [ -L "$FAKE_HOME/.codex/agents/code-reviewer-comment.toml" ]
    [ -L "$FAKE_HOME/.codex/agents/code-reviewer-security.toml" ]
    [[ "$(readlink "$FAKE_HOME/.codex/agents/code-reviewer-security.toml")" == "$FAKE_HOME/.codex/.review-code-agents/"* ]]
}

@test "install-codex.sh: refuses to overwrite a real file at the destination" {
    mkdir -p "$FAKE_HOME/.codex/agents"
    echo "user-authored" > "$FAKE_HOME/.codex/agents/code-reviewer-security.toml"
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    # The file must be unchanged and the installer must have warned.
    [ -f "$FAKE_HOME/.codex/agents/code-reviewer-security.toml" ]
    [ ! -L "$FAKE_HOME/.codex/agents/code-reviewer-security.toml" ]
    [[ "$(cat "$FAKE_HOME/.codex/agents/code-reviewer-security.toml")" == "user-authored" ]]
    [[ "$output" == *"code-reviewer-security.toml"* ]]
}

@test "install-codex.sh: refuses to overwrite a symlink it does not own" {
    mkdir -p "$FAKE_HOME/.codex/agents" "$FAKE_HOME/elsewhere"
    echo "elsewhere" > "$FAKE_HOME/elsewhere/foreign.toml"
    ln -s "$FAKE_HOME/elsewhere/foreign.toml" "$FAKE_HOME/.codex/agents/code-reviewer-security.toml"
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    [ -L "$FAKE_HOME/.codex/agents/code-reviewer-security.toml" ]
    [[ "$(readlink "$FAKE_HOME/.codex/agents/code-reviewer-security.toml")" == *"foreign.toml" ]]
    [[ "$output" == *"unmanaged"* ]]
}

@test "install-codex.sh: replaces a symlink it already owns" {
    # First run.
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    # Second run should succeed and keep the link.
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    [ -L "$FAKE_HOME/.codex/agents/code-reviewer-security.toml" ]
    [[ "$(readlink "$FAKE_HOME/.codex/agents/code-reviewer-security.toml")" == "$FAKE_HOME/.codex/.review-code-agents/"* ]]
}

@test "install-codex.sh: --uninstall removes managed symlinks and staging" {
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    [ -L "$FAKE_HOME/.codex/agents/code-reviewer-security.toml" ]
    run sh "$INSTALLER" --uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$FAKE_HOME/.codex/.review-code-agents" ]
    [ ! -L "$FAKE_HOME/.codex/agents/code-reviewer-security.toml" ]
}

@test "install-codex.sh: --uninstall leaves user-owned files alone" {
    mkdir -p "$FAKE_HOME/.codex/agents"
    echo "user-authored" > "$FAKE_HOME/.codex/agents/code-reviewer-security.toml"
    run sh "$INSTALLER" --uninstall
    [ "$status" -eq 0 ]
    [ -f "$FAKE_HOME/.codex/agents/code-reviewer-security.toml" ]
    [[ "$(cat "$FAKE_HOME/.codex/agents/code-reviewer-security.toml")" == "user-authored" ]]
}

@test "install-codex.sh: render failure leaves prior install in place" {
    run sh "$INSTALLER"
    [ "$status" -eq 0 ]
    # Sabotage by shadowing python3 with one that always fails.
    local mockbin
    mockbin=$(mktemp -d)
    printf '#!/bin/sh\nexit 1\n' > "$mockbin/python3"
    chmod +x "$mockbin/python3"
    PATH="$mockbin:$PATH" run sh "$INSTALLER"
    rm -rf "$mockbin"
    [ "$status" -ne 0 ]
    # Old links should still be intact.
    [ -L "$FAKE_HOME/.codex/agents/code-reviewer-security.toml" ]
}
