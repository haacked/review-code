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
    unset REVIEW_CODE_WORKTREE_DIR
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
    [ -f "$TEST_HOME/.agents/skills/review-code/.install-manifest" ]
    grep -q $'\tSKILL.md$' "$TEST_HOME/.agents/skills/review-code/.install-manifest"
    grep -q $'\tscripts/pr-worktree.sh$' "$TEST_HOME/.agents/skills/review-code/.install-manifest"
}

@test "setup: uninstall keeps a registered worktree and its Git registration" {
    create_migration_repo
    bin/setup > /dev/null
    local root="$TEST_HOME/.agents/skills/review-code"
    local checkout="$root/.worktrees/org/repo/pr-1"
    add_migration_worktree "$checkout" 'unfinished review'
    local registrations
    registrations="$(git -C "$MIGRATION_REPO" worktree list --porcelain)"

    run bash "$TEST_HOME/.agents/bin/uninstall-review-code.sh"
    [ "$status" -eq 0 ]
    [ -d "$root" ]
    [ ! -f "$root/SKILL.md" ]
    [ ! -f "$root/scripts/pr-worktree.sh" ]
    [ ! -f "$root/context/languages/bash.md" ]
    [ "$(cat "$checkout/file.txt")" = 'unfinished review' ]
    [ "$(git -C "$MIGRATION_REPO" worktree list --porcelain)" = "$registrations" ]
    run git -C "$checkout" status --porcelain
    [ "$status" -eq 0 ]
    [[ "$output" == *' M file.txt'* ]]
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

create_migration_repo() {
    MIGRATION_REPO="$TEST_HOME/clone"
    git init --quiet "$MIGRATION_REPO"
    git -C "$MIGRATION_REPO" config commit.gpgsign false
    git -C "$MIGRATION_REPO" config user.email "test@example.com"
    git -C "$MIGRATION_REPO" config user.name "Test User"
    echo "tracked" > "$MIGRATION_REPO/file.txt"
    git -C "$MIGRATION_REPO" add file.txt
    git -C "$MIGRATION_REPO" commit --quiet -m "initial"
}

add_migration_worktree() {
    local destination="$1"
    local content="$2"
    mkdir -p "$(dirname "$destination")"
    git -C "$MIGRATION_REPO" worktree add --detach --quiet "$destination" HEAD
    echo "$content" > "$destination/file.txt"
}

assert_migration_worktree() {
    local destination="$1"
    local content="$2"
    [ "$(cat "$destination/file.txt")" = "$content" ]
    run git -C "$destination" status --porcelain
    [ "$status" -eq 0 ]
    [[ "$output" == *" M file.txt"* ]]
}

@test "setup: migrates registered worktrees into an override without losing existing checkouts" {
    create_migration_repo
    local legacy="$TEST_HOME/.claude/skills/review-code"
    local canonical="$TEST_HOME/.agents/skills/review-code"
    export REVIEW_CODE_WORKTREE_DIR="$TEST_HOME/review worktrees"
    add_migration_worktree "$legacy/.worktrees/org/repo/pr-1" "legacy hidden"
    add_migration_worktree "$legacy/worktrees/org/repo/pr-2" "legacy visible"
    add_migration_worktree "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-3" "existing override"
    add_migration_worktree "$canonical/.worktrees/org/repo/pr-4" "existing canonical"
    git -C "$MIGRATION_REPO" worktree lock "$legacy/.worktrees/org/repo/pr-1" --reason "active review"
    local registrations
    registrations="$(git -C "$MIGRATION_REPO" worktree list --porcelain)"

    run bin/setup
    [ "$status" -eq 0 ]

    assert_migration_worktree "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-1" "legacy hidden"
    assert_migration_worktree "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-2" "legacy visible"
    assert_migration_worktree "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-3" "existing override"
    assert_migration_worktree "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-4" "existing canonical"
    assert_migration_worktree "$legacy/.worktrees/org/repo/pr-1" "legacy hidden"
    assert_migration_worktree "$legacy/worktrees/org/repo/pr-2" "legacy visible"
    assert_migration_worktree "$canonical/.worktrees/org/repo/pr-4" "existing canonical"
    [ "$(git -C "$MIGRATION_REPO" worktree list --porcelain)" = "$registrations" ]
    run git -C "$MIGRATION_REPO" worktree prune --dry-run --verbose --expire now
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "setup: merges nonconflicting registered worktrees into the canonical default" {
    create_migration_repo
    local legacy="$TEST_HOME/.claude/skills/review-code"
    local canonical="$TEST_HOME/.agents/skills/review-code"
    add_migration_worktree "$legacy/.worktrees/org/repo/pr-1" "legacy checkout"
    add_migration_worktree "$canonical/.worktrees/org/repo/pr-2" "canonical checkout"
    local registrations
    registrations="$(git -C "$MIGRATION_REPO" worktree list --porcelain)"

    run bin/setup
    [ "$status" -eq 0 ]

    assert_migration_worktree "$canonical/.worktrees/org/repo/pr-1" "legacy checkout"
    assert_migration_worktree "$canonical/.worktrees/org/repo/pr-2" "canonical checkout"
    assert_migration_worktree "$legacy/.worktrees/org/repo/pr-1" "legacy checkout"
    [ "$(git -C "$MIGRATION_REPO" worktree list --porcelain)" = "$registrations" ]
}

@test "setup: migrated dirty worktrees can be removed by teardown" {
    create_migration_repo
    local legacy="$TEST_HOME/.claude/skills/review-code"
    local canonical="$TEST_HOME/.agents/skills/review-code"
    export REVIEW_CODE_WORKTREE_DIR="$TEST_HOME/review worktrees"
    add_migration_worktree "$legacy/.worktrees/org/repo/pr-1" "unfinished review"
    git -C "$MIGRATION_REPO" worktree lock "$legacy/.worktrees/org/repo/pr-1" --reason "active review"

    run bin/setup
    [ "$status" -eq 0 ]
    assert_migration_worktree "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-1" "unfinished review"

    run "$canonical/scripts/pr-worktree.sh" teardown org repo 1 "$MIGRATION_REPO"
    [ "$status" -eq 0 ]
    [ ! -e "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-1" ]
    [ ! -e "$legacy/.worktrees/org/repo/pr-1" ]
    run git -C "$MIGRATION_REPO" worktree list --porcelain
    [ "$status" -eq 0 ]
    [[ "$output" != *"/pr-1"* ]]
}

@test "setup: migrated dirty worktrees can be provisioned for an updated PR" {
    create_migration_repo
    local legacy="$TEST_HOME/.claude/skills/review-code"
    local canonical="$TEST_HOME/.agents/skills/review-code"
    local origin="$TEST_HOME/origin.git"
    add_migration_worktree "$legacy/.worktrees/org/repo/pr-1" "unfinished review"
    git -C "$MIGRATION_REPO" worktree lock "$legacy/.worktrees/org/repo/pr-1" --reason "active review"
    echo "updated PR" > "$MIGRATION_REPO/file.txt"
    git -C "$MIGRATION_REPO" commit --quiet -am "update PR"
    git init --bare --quiet "$origin"
    git -C "$MIGRATION_REPO" remote add origin "$origin"
    git -C "$MIGRATION_REPO" push --quiet origin HEAD:refs/pull/1/head

    run bin/setup
    [ "$status" -eq 0 ]
    assert_migration_worktree "$canonical/.worktrees/org/repo/pr-1" "unfinished review"

    run "$canonical/scripts/pr-worktree.sh" provision org repo 1 "$MIGRATION_REPO"
    [ "$status" -eq 0 ]
    [ "$(cat "$canonical/.worktrees/org/repo/pr-1/file.txt")" = "updated PR" ]
    run git -C "$canonical/.worktrees/org/repo/pr-1" status --porcelain
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run git -C "$MIGRATION_REPO" worktree list --porcelain
    [ "$status" -eq 0 ]
    [ "$(grep -c '^worktree ' <<< "$output")" -eq 2 ]
}

@test "setup: worktree collisions abort before moving or deleting legacy state" {
    create_migration_repo
    local legacy="$TEST_HOME/.claude/skills/review-code"
    local canonical="$TEST_HOME/.agents/skills/review-code"
    export REVIEW_CODE_WORKTREE_DIR="$TEST_HOME/review worktrees"
    add_migration_worktree "$legacy/.worktrees/org/repo/pr-1" "legacy checkout"
    add_migration_worktree "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-1" "existing checkout"
    add_migration_worktree "$legacy/.worktrees/org/repo/pr-2" "nonconflicting checkout"
    mkdir -p "$legacy/.reviews/org/repo" "$legacy/.sessions"
    echo "review body" > "$legacy/.reviews/org/repo/pr-1.md"
    echo "session state" > "$legacy/.sessions/session.json"
    local registrations
    registrations="$(git -C "$MIGRATION_REPO" worktree list --porcelain)"

    run bin/setup
    [ "$status" -ne 0 ]

    [ ! -L "$legacy" ]
    assert_migration_worktree "$legacy/.worktrees/org/repo/pr-1" "legacy checkout"
    assert_migration_worktree "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-1" "existing checkout"
    assert_migration_worktree "$legacy/.worktrees/org/repo/pr-2" "nonconflicting checkout"
    [ "$(cat "$legacy/.reviews/org/repo/pr-1.md")" = "review body" ]
    [ "$(cat "$legacy/.sessions/session.json")" = "session state" ]
    [ ! -e "$canonical/.reviews/org/repo/pr-1.md" ]
    [ ! -e "$REVIEW_CODE_WORKTREE_DIR/org/repo/pr-2" ]
    [ "$(git -C "$MIGRATION_REPO" worktree list --porcelain)" = "$registrations" ]
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
