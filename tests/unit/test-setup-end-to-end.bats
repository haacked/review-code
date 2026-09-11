#!/usr/bin/env bats
# End-to-end coverage for bin/setup. Existing test-setup.bats asserts on
# source content; these tests execute setup in a fake HOME so migration,
# symlink, and harness-gating behavior actually run.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    TEST_HOME="$(mktemp -d)"
    export TEST_HOME

    # Redirect config writes away from the real home.
    export HOME="$TEST_HOME"
    export CODEX_HOME="$TEST_HOME/.codex"
    mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.agents" "$TEST_HOME/.codex"
}

teardown() {
    [ -d "$TEST_HOME" ] && rm -rf "$TEST_HOME"
}

# =============================================================================
# Fresh install
# =============================================================================

@test "setup: installs to ~/.agents/skills/review-code as canonical" {
    run bin/setup
    [ "$status" -eq 0 ]
    [ -d "$TEST_HOME/.agents/skills/review-code" ]
    [ -f "$TEST_HOME/.agents/skills/review-code/SKILL.md" ]
    [ -d "$TEST_HOME/.agents/skills/review-code/scripts" ]
    [ -d "$TEST_HOME/.agents/skills/review-code/handlers" ]
    [ -d "$TEST_HOME/.agents/skills/review-code/context" ]
}

@test "setup: creates Claude compatibility symlink at ~/.claude/skills/review-code" {
    run bin/setup
    [ "$status" -eq 0 ]
    [ -L "$TEST_HOME/.claude/skills/review-code" ]
    [ "$(readlink "$TEST_HOME/.claude/skills/review-code")" = "$TEST_HOME/.agents/skills/review-code" ]
}

@test "setup: installs Codex agent TOMLs and symlinks them into ~/.codex/agents" {
    run bin/setup
    [ "$status" -eq 0 ]
    [ -d "$TEST_HOME/.codex/.review-code-agents" ]
    [ -d "$TEST_HOME/.codex/agents" ]
    # Spot-check a few names; the full list lives in agents/.
    [ -e "$TEST_HOME/.codex/agents/code-reviewer-security.toml" ]
    [ -e "$TEST_HOME/.codex/agents/code-reviewer-correctness.toml" ]
    [ -e "$TEST_HOME/.codex/agents/code-review-context-explorer.toml" ]
}

@test "setup: SessionStart hook installed when ~/.claude exists" {
    run bin/setup
    [ "$status" -eq 0 ]
    [ -f "$TEST_HOME/.claude/settings.json" ]
    grep -q 'SessionStart' "$TEST_HOME/.claude/settings.json"
}

@test "setup: install_agents_to installs Claude agent .md files" {
    run bin/setup
    [ "$status" -eq 0 ]
    [ -f "$TEST_HOME/.claude/agents/code-reviewer-security.md" ]
    [ -f "$TEST_HOME/.claude/agents/code-review-context-explorer.md" ]
}

# =============================================================================
# Codex-only install (no ~/.claude)
# =============================================================================

@test "setup: Codex-only install skips Claude-only steps and does not create ~/.claude" {
    rm -rf "$TEST_HOME/.claude"

    run bin/setup
    [ "$status" -eq 0 ]
    [ -d "$TEST_HOME/.agents/skills/review-code" ]
    [ -d "$TEST_HOME/.codex/agents" ]
    # The bug the reviewer caught: ~/.claude must not be created on a
    # Codex-only machine. Check it's still absent after the full install.
    [ ! -d "$TEST_HOME/.claude" ]
}

@test "setup: Codex-only install skips SessionStart hook" {
    rm -rf "$TEST_HOME/.claude"

    run bin/setup
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_HOME/.claude/settings.json" ]
}

# =============================================================================
# Migration: legacy real-dir install at ~/.claude/skills/review-code
# =============================================================================

@test "setup: migrates legacy real-dir skill install to canonical location" {
    mkdir -p "$TEST_HOME/.claude/skills/review-code/.learnings"
    mkdir -p "$TEST_HOME/.claude/skills/review-code/.reviews/posthog/posthog"
    mkdir -p "$TEST_HOME/.claude/skills/review-code/.worktrees/posthog/posthog/pr-1"
    mkdir -p "$TEST_HOME/.claude/skills/review-code/.sessions"
    echo '{"user":true}' > "$TEST_HOME/.claude/skills/review-code/.learnings/index.jsonl"
    echo 'review-body' > "$TEST_HOME/.claude/skills/review-code/.reviews/posthog/posthog/pr-1.md"
    echo 'worktree-marker' > "$TEST_HOME/.claude/skills/review-code/.worktrees/posthog/posthog/pr-1/README"
    echo 'session-marker' > "$TEST_HOME/.claude/skills/review-code/.sessions/old-session.json"
    echo 'posthog/posthog ~/dev/posthog/posthog' > "$TEST_HOME/.claude/skills/review-code/repos.conf"
    echo 'legacy-skill-md' > "$TEST_HOME/.claude/skills/review-code/SKILL.md"

    run bin/setup
    [ "$status" -eq 0 ]

    # Canonical gets user content.
    [ -f "$TEST_HOME/.agents/skills/review-code/.learnings/index.jsonl" ]
    grep -q '"user":true' "$TEST_HOME/.agents/skills/review-code/.learnings/index.jsonl"
    [ -f "$TEST_HOME/.agents/skills/review-code/.reviews/posthog/posthog/pr-1.md" ]
    grep -q 'review-body' "$TEST_HOME/.agents/skills/review-code/.reviews/posthog/posthog/pr-1.md"
    [ -f "$TEST_HOME/.agents/skills/review-code/repos.conf" ]
    grep -q 'posthog/posthog' "$TEST_HOME/.agents/skills/review-code/repos.conf"

    # New SKILL.md replaces the legacy one (code, not preserved content).
    ! grep -q 'legacy-skill-md' "$TEST_HOME/.agents/skills/review-code/SKILL.md"

    # Claude path becomes a symlink.
    [ -L "$TEST_HOME/.claude/skills/review-code" ]
}

@test "setup: re-run on canonical layout preserves user-facing tree" {
    bin/setup > /dev/null
    first_manifest="$(find "$TEST_HOME/.agents/skills/review-code" -type f ! -name '*.bak' | sort)"

    run bin/setup
    [ "$status" -eq 0 ]
    # .bak files created on the second pass are setup's own safety side
    # effect; the user-facing skill tree must be unchanged.
    second_manifest="$(find "$TEST_HOME/.agents/skills/review-code" -type f ! -name '*.bak' | sort)"
    [ "$first_manifest" = "$second_manifest" ]
    [ -L "$TEST_HOME/.claude/skills/review-code" ]
}

# =============================================================================
# Guard: existing real-dir destination stays the user's problem
# =============================================================================

@test "setup: leaves user-owned files in ~/.codex/agents alone" {
    mkdir -p "$TEST_HOME/.codex/agents"
    echo 'user-authored' > "$TEST_HOME/.codex/agents/code-reviewer-security.toml"

    run bin/setup
    [ "$status" -eq 0 ]
    [ -f "$TEST_HOME/.codex/agents/code-reviewer-security.toml" ]
    [ ! -L "$TEST_HOME/.codex/agents/code-reviewer-security.toml" ]
    grep -q 'user-authored' "$TEST_HOME/.codex/agents/code-reviewer-security.toml"
}
