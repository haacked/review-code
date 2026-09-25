#!/usr/bin/env bats
# Tests for uninstall.sh
#
# The standalone installer must also work after the source repo is gone.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
}

# =============================================================================
# Function existence tests
# =============================================================================

@test "uninstall.sh: has remove_skill function" {
    run bash -c "grep -q '^remove_skill()' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: has remove_agents function" {
    run bash -c "grep -q '^remove_agents()' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: has preserve_reviews function" {
    run bash -c "grep -q '^preserve_reviews()' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: has cleanup_old_config_files function" {
    run bash -c "grep -q '^cleanup_old_config_files()' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: has main function" {
    run bash -c "grep -q '^main()' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Agent removal tests
# =============================================================================

@test "uninstall.sh: removes security agent" {
    run bash -c "grep -A50 'remove_agents()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'code-reviewer-security'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: removes performance agent" {
    run bash -c "grep -A50 'remove_agents()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'code-reviewer-performance'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: removes correctness agent" {
    run bash -c "grep -A50 'remove_agents()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'code-reviewer-correctness'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: removes maintainability agent" {
    run bash -c "grep -A50 'remove_agents()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'code-reviewer-maintainability'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: removes testing agent" {
    run bash -c "grep -A50 'remove_agents()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'code-reviewer-testing'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: removes compatibility agent" {
    run bash -c "grep -A50 'remove_agents()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'code-reviewer-compatibility'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: removes architecture agent" {
    run bash -c "grep -A50 'remove_agents()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'code-reviewer-architecture'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: removes context explorer agent" {
    run bash -c "grep -A50 'remove_agents()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'code-review-context-explorer'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: remove_agents cleans PostHog Desktop config homes" {
    TEST_TEMP_DIR=$(mktemp -d)
    fake_home="${TEST_TEMP_DIR}/home"
    claude_agents="${fake_home}/.claude/agents"
    app_agents="${fake_home}/Library/Application Support/@posthog/posthog-code/claude/agents"
    mkdir -p "${claude_agents}" "${app_agents}"
    touch "${claude_agents}/code-reviewer-security.md" "${app_agents}/code-reviewer-security.md"

    run bash -c "
        set -euo pipefail
        info() { :; }
        warn() { :; }
        error() { :; }
        HOME='${fake_home}'
        CLAUDE_DIR='${fake_home}/.claude'
        source <(sed -n '/^remove_agents()/,/^}/p' '$PROJECT_ROOT/uninstall.sh')
        remove_agents
    "

    [ "$status" -eq 0 ]
    [ ! -e "${claude_agents}/code-reviewer-security.md" ]
    [ ! -e "${app_agents}/code-reviewer-security.md" ]

    rm -rf "${TEST_TEMP_DIR}"
}

@test "uninstall.sh: remove_agents handles absent PostHog Desktop config homes" {
    TEST_TEMP_DIR=$(mktemp -d)
    fake_home="${TEST_TEMP_DIR}/home"
    claude_agents="${fake_home}/.claude/agents"
    mkdir -p "${claude_agents}"
    touch "${claude_agents}/code-reviewer-security.md"

    run bash -c "
        set -euo pipefail
        info() { :; }
        warn() { :; }
        error() { :; }
        HOME='${fake_home}'
        CLAUDE_DIR='${fake_home}/.claude'
        source <(sed -n '/^remove_agents()/,/^}/p' '$PROJECT_ROOT/uninstall.sh')
        remove_agents
    "

    [ "$status" -eq 0 ]
    [ ! -e "${claude_agents}/code-reviewer-security.md" ]

    rm -rf "${TEST_TEMP_DIR}"
}

# =============================================================================
# Script removal tests
# =============================================================================

@test "uninstall.sh: removes uninstall script itself" {
    run bash -c "grep -A50 'remove_skill()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'uninstall-review-code.sh'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# User interaction tests
# =============================================================================

@test "uninstall.sh: prompts before removing reviews" {
    run bash -c "grep -A25 'preserve_reviews()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'read -p'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: offers to backup reviews" {
    run bash -c "grep -A25 'preserve_reviews()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'review-code-backup'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Path tests
# =============================================================================

@test "uninstall.sh: uses fixed dot-prefixed REVIEWS_DIR path" {
    run bash -c "grep -q 'REVIEWS_DIR=\"\${SKILL_DIR}/\.reviews\"' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: cleans up old config files" {
    run bash -c "grep -A20 'cleanup_old_config_files()' '$PROJECT_ROOT/uninstall.sh' | grep -q '.env'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "uninstall.sh: has correct shebang" {
    run bash -c "head -1 '$PROJECT_ROOT/uninstall.sh' | grep -q '^#!/bin/bash'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: uses set -euo pipefail" {
    run bash -c "head -30 '$PROJECT_ROOT/uninstall.sh' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: calls main function at end" {
    run bash -c "tail -5 '$PROJECT_ROOT/uninstall.sh' | grep -q 'main'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Workflow tests
# =============================================================================

@test "uninstall.sh: main calls preserve_reviews" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'preserve_reviews'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: main calls remove_skill" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'remove_skill'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: main calls remove_agents" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'remove_agents'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: main calls cleanup_old_config_files" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'cleanup_old_config_files'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Output message tests
# =============================================================================

@test "uninstall.sh: displays uninstaller banner" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'Review-Code Uninstaller'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: displays completion message" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'Uninstallation complete'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: shows reinstall instructions" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'To reinstall'"
    [ "$status" -eq 0 ]
}

prepare_standalone_uninstall() {
    UNINSTALL_HOME="$BATS_TEST_TMPDIR/home"
    UNINSTALL_CANONICAL="$UNINSTALL_HOME/.agents/skills/review-code"
    UNINSTALL_SCRIPT="$UNINSTALL_HOME/.agents/bin/uninstall-review-code.sh"
    mkdir -p "$UNINSTALL_CANONICAL" "$(dirname "$UNINSTALL_SCRIPT")"
    cp "$PROJECT_ROOT/uninstall.sh" "$UNINSTALL_SCRIPT"
    echo "installed skill" > "$UNINSTALL_CANONICAL/SKILL.md"
}

run_standalone_uninstall() {
    run env HOME="$UNINSTALL_HOME" CODEX_HOME="${1:-$UNINSTALL_HOME/.codex}" bash "$UNINSTALL_SCRIPT" <<< "y"
}

write_managed_codex_agent() {
    printf '%s\n' '# Managed by bin/install-codex.sh from the review-code repo.' 'name = "reviewer"' > "$1"
}

@test "uninstall.sh: standalone removal backs up canonical reviews and removes its own script" {
    prepare_standalone_uninstall
    local legacy="$UNINSTALL_HOME/.claude/skills/review-code"
    mkdir -p "$(dirname "$legacy")" "$UNINSTALL_CANONICAL/.reviews/org/repo" "$UNINSTALL_CANONICAL/reviews/org/repo"
    ln -s "$UNINSTALL_CANONICAL" "$legacy"
    echo "current review" > "$UNINSTALL_CANONICAL/.reviews/org/repo/current.md"
    echo "visible review" > "$UNINSTALL_CANONICAL/reviews/org/repo/visible.md"
    echo "older copy" > "$UNINSTALL_CANONICAL/reviews/org/repo/current.md"

    run_standalone_uninstall
    [ "$status" -eq 0 ]

    [ ! -e "$UNINSTALL_CANONICAL" ]
    [ ! -L "$legacy" ]
    [ ! -e "$UNINSTALL_SCRIPT" ]
    local backups=("$UNINSTALL_HOME"/review-code-backup-*)
    [ "${#backups[@]}" -eq 1 ]
    [ "$(cat "${backups[0]}/reviews/org/repo/current.md")" = "current review" ]
    [ "$(cat "${backups[0]}/reviews/org/repo/visible.md")" = "visible review" ]
}

@test "uninstall.sh: standalone removal backs up a legacy real-directory installation" {
    prepare_standalone_uninstall
    rm -rf "$UNINSTALL_CANONICAL"
    local legacy="$UNINSTALL_HOME/.claude/skills/review-code"
    mkdir -p "$legacy/.reviews/org/repo" "$legacy/reviews/org/repo"
    echo "current review" > "$legacy/.reviews/org/repo/current.md"
    echo "legacy review" > "$legacy/reviews/org/repo/legacy.md"
    echo "older copy" > "$legacy/reviews/org/repo/current.md"

    run_standalone_uninstall
    [ "$status" -eq 0 ]

    [ ! -e "$legacy" ]
    local backups=("$UNINSTALL_HOME"/review-code-backup-*)
    [ "${#backups[@]}" -eq 1 ]
    [ "$(cat "${backups[0]}/reviews/org/repo/current.md")" = "current review" ]
    [ "$(cat "${backups[0]}/reviews/org/repo/legacy.md")" = "legacy review" ]
}

@test "uninstall.sh: backs up reviews from canonical and legacy directories together" {
    prepare_standalone_uninstall
    local legacy="$UNINSTALL_HOME/.claude/skills/review-code"
    mkdir -p "$legacy/.reviews/org/repo" "$UNINSTALL_CANONICAL/.reviews/org/repo"
    echo "legacy review" > "$legacy/.reviews/org/repo/legacy.md"
    echo "canonical review" > "$UNINSTALL_CANONICAL/.reviews/org/repo/canonical.md"

    run_standalone_uninstall
    [ "$status" -eq 0 ]

    local backups=("$UNINSTALL_HOME"/review-code-backup-*)
    [ "${#backups[@]}" -eq 1 ]
    [ "$(cat "${backups[0]}/reviews/org/repo/legacy.md")" = "legacy review" ]
    [ "$(cat "${backups[0]}/reviews/org/repo/canonical.md")" = "canonical review" ]
}

@test "uninstall.sh: leaves a Claude skill link targeting a foreign installation intact" {
    prepare_standalone_uninstall
    local legacy="$UNINSTALL_HOME/.claude/skills/review-code"
    local foreign="$UNINSTALL_HOME/foreign-skill"
    mkdir -p "$(dirname "$legacy")" "$foreign"
    echo "foreign skill" > "$foreign/SKILL.md"
    echo "foreign config" > "$foreign/.env"
    ln -s "$foreign" "$legacy"

    run_standalone_uninstall
    [ "$status" -eq 0 ]

    [ -L "$legacy" ]
    [ "$(readlink "$legacy")" = "$foreign" ]
    [ "$(cat "$foreign/SKILL.md")" = "foreign skill" ]
    [ "$(cat "$foreign/.env")" = "foreign config" ]
    [ ! -e "$UNINSTALL_CANONICAL" ]
}

@test "uninstall.sh: removes dangling Claude compatibility links targeting canonical" {
    prepare_standalone_uninstall
    rm -rf "$UNINSTALL_CANONICAL"
    local legacy="$UNINSTALL_HOME/.claude/skills/review-code"
    mkdir -p "$(dirname "$legacy")"
    ln -s "$UNINSTALL_CANONICAL" "$legacy"

    run_standalone_uninstall
    [ "$status" -eq 0 ]
    [ ! -L "$legacy" ]
    [ ! -e "$UNINSTALL_SCRIPT" ]
}

@test "uninstall.sh: removes owned Codex agents while preserving foreign files and links" {
    prepare_standalone_uninstall
    local codex_dir="$UNINSTALL_HOME/.codex"
    local staging="$codex_dir/.review-code-agents"
    local agents="$codex_dir/agents"
    local foreign="$UNINSTALL_HOME/foreign-agent.toml"
    mkdir -p "$staging" "$agents"
    write_managed_codex_agent "$staging/code-reviewer-security.toml"
    write_managed_codex_agent "$agents/code-reviewer-correctness.toml"
    ln -s "$staging/code-reviewer-security.toml" "$agents/code-reviewer-security.toml"
    ln -s "$staging/retired-reviewer.toml" "$agents/retired-reviewer.toml"
    echo "foreign agent" > "$foreign"
    ln -s "$foreign" "$agents/code-reviewer-performance.toml"
    echo "user-authored agent" > "$agents/code-reviewer-testing.toml"
    echo "user-authored staging file" > "$staging/custom.toml"

    run_standalone_uninstall
    [ "$status" -eq 0 ]

    [ ! -L "$agents/code-reviewer-security.toml" ]
    [ ! -L "$agents/retired-reviewer.toml" ]
    [ ! -e "$agents/code-reviewer-correctness.toml" ]
    [ ! -e "$staging/code-reviewer-security.toml" ]
    [ -L "$agents/code-reviewer-performance.toml" ]
    [ "$(cat "$foreign")" = "foreign agent" ]
    [ "$(cat "$agents/code-reviewer-testing.toml")" = "user-authored agent" ]
    [ "$(cat "$staging/custom.toml")" = "user-authored staging file" ]
}

@test "uninstall.sh: honors CODEX_HOME without removing agents in the default home" {
    prepare_standalone_uninstall
    local codex_dir="$UNINSTALL_HOME/custom codex"
    local staging="$codex_dir/.review-code-agents"
    local agents="$codex_dir/agents"
    local default_agents="$UNINSTALL_HOME/.codex/agents"
    mkdir -p "$staging" "$agents" "$default_agents"
    write_managed_codex_agent "$staging/code-reviewer-security.toml"
    ln -s "$staging/code-reviewer-security.toml" "$agents/code-reviewer-security.toml"
    write_managed_codex_agent "$default_agents/code-reviewer-security.toml"

    run_standalone_uninstall "$codex_dir"
    [ "$status" -eq 0 ]

    [ ! -L "$agents/code-reviewer-security.toml" ]
    [ ! -e "$staging/code-reviewer-security.toml" ]
    [ -f "$default_agents/code-reviewer-security.toml" ]
}
