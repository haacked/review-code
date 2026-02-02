#!/usr/bin/env bats
# Simplified tests for bin/setup

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
}

# =============================================================================
# Core security tests - Safe config loading
# =============================================================================

@test "setup: does not use 'source' for config loading" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/bin/setup' | grep -v '^#' | grep -q '^[[:space:]]*source '"
    [ "$status" -ne 0 ]
}

@test "setup: validates config key format with regex" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/bin/setup' | grep -q '\[A-Z_\]\[A-Z0-9_\]'"
    [ "$status" -eq 0 ]
}

@test "setup: uses case statement for safe variable assignment" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/bin/setup' | grep -q 'case.*in'"
    [ "$status" -eq 0 ]
}

@test "setup: load_config_safely checks file ownership" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/bin/setup' | grep -q 'file_owner'"
    [ "$status" -eq 0 ]
}

@test "setup: load_config_safely checks world-writable permissions" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/bin/setup' | grep -q 'world-writable'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Function existence tests
# =============================================================================

@test "setup: has check_prerequisites function" {
    run bash -c "grep -q '^check_prerequisites()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has verify_repo_structure function" {
    run bash -c "grep -q '^verify_repo_structure()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has load_config_safely function" {
    run bash -c "grep -q '^load_config_safely()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has create_config function" {
    run bash -c "grep -q '^create_config()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has install_skill function" {
    run bash -c "grep -q '^install_skill()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has install_agents function" {
    run bash -c "grep -q '^install_agents()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has install_context function" {
    run bash -c "grep -q '^install_context()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has main function" {
    run bash -c "grep -q '^main()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Agent installation tests
# =============================================================================

@test "setup: installs security agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-security'"
    [ "$status" -eq 0 ]
}

@test "setup: installs performance agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-performance'"
    [ "$status" -eq 0 ]
}

@test "setup: installs maintainability agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-maintainability'"
    [ "$status" -eq 0 ]
}

@test "setup: installs testing agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-testing'"
    [ "$status" -eq 0 ]
}

@test "setup: installs compatibility agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-compatibility'"
    [ "$status" -eq 0 ]
}

@test "setup: installs architecture agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-reviewer-architecture'"
    [ "$status" -eq 0 ]
}

@test "setup: installs context explorer agent" {
    run bash -c "grep -A50 'install_agents()' '$PROJECT_ROOT/bin/setup' | grep -q 'code-review-context-explorer'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Prerequisites checking
# =============================================================================

@test "setup: checks for bash 4.0+" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'BASH_VERSINFO'"
    [ "$status" -eq 0 ]
}

@test "setup: checks for git" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'git'"
    [ "$status" -eq 0 ]
}

@test "setup: checks for gh CLI" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'gh'"
    [ "$status" -eq 0 ]
}

@test "setup: checks for jq" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'jq'"
    [ "$status" -eq 0 ]
}

@test "setup: checks for ~/.claude directory" {
    run bash -c "grep -A30 'check_prerequisites()' '$PROJECT_ROOT/bin/setup' | grep -q 'CLAUDE_DIR'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "setup: has correct shebang" {
    run bash -c "head -1 '$PROJECT_ROOT/bin/setup' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "setup: uses set -euo pipefail" {
    run bash -c "head -30 '$PROJECT_ROOT/bin/setup' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "setup: calls main function at end" {
    run bash -c "tail -5 '$PROJECT_ROOT/bin/setup' | grep -q 'main'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Context installation tests
# =============================================================================

@test "setup: install_context creates languages directory" {
    run bash -c "grep -A100 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'languages'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context creates frameworks directory" {
    run bash -c "grep -A100 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'frameworks'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context creates orgs directory" {
    run bash -c "grep -A100 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'orgs'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context backs up modified files" {
    run bash -c "grep -A100 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q '.bak'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context compares file checksums" {
    run bash -c "grep -A100 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'get_file_checksum'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Skill installation tests
# =============================================================================

@test "setup: install_skill copies SKILL.md" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'SKILL.md'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill makes scripts executable" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'chmod +x'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill copies uninstall script" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill creates scripts directory" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'scripts'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Workflow tests
# =============================================================================

@test "setup: main calls check_prerequisites" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'check_prerequisites'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls verify_repo_structure" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'verify_repo_structure'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls create_config" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'create_config'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls install_skill" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'install_skill'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls install_agents" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'install_agents'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls install_context" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'install_context'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# migrate_old_config tests
# =============================================================================

@test "setup: has migrate_old_config function" {
    run bash -c "grep -q '^migrate_old_config()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: main calls migrate_old_config" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'migrate_old_config'"
    [ "$status" -eq 0 ]
}

@test "setup: migrate_old_config checks for old config file existence" {
    run bash -c "grep -A20 '^migrate_old_config()' '$PROJECT_ROOT/bin/setup' | grep -q 'OLD_CONFIG_FILE'"
    [ "$status" -eq 0 ]
}

@test "setup: migrate_old_config checks for new config file existence" {
    run bash -c "grep -A20 '^migrate_old_config()' '$PROJECT_ROOT/bin/setup' | grep -q 'CONFIG_FILE'"
    [ "$status" -eq 0 ]
}

@test "setup: migrate_old_config uses mv for migration" {
    # Test that migration uses mv to move old config to new location
    run bash -c "grep -A20 '^migrate_old_config()' '$PROJECT_ROOT/bin/setup' | grep -q 'mv'"
    [ "$status" -eq 0 ]
}

@test "setup: migrate_old_config uses diff to compare configs" {
    # Test that deduplication uses diff to compare old and new configs
    run bash -c "grep -A20 '^migrate_old_config()' '$PROJECT_ROOT/bin/setup' | grep -q 'diff -q'"
    [ "$status" -eq 0 ]
}

@test "setup: migrate_old_config removes duplicate old config" {
    # Test that when configs are identical, old one is removed
    run bash -c "grep -A20 '^migrate_old_config()' '$PROJECT_ROOT/bin/setup' | grep -q 'rm.*OLD_CONFIG_FILE'"
    [ "$status" -eq 0 ]
}

@test "setup: migrate_old_config warns on conflict" {
    # Test that when configs differ, a warning is issued
    run bash -c "grep -A20 '^migrate_old_config()' '$PROJECT_ROOT/bin/setup' | grep -q 'Both old and new config files exist with different content'"
    [ "$status" -eq 0 ]
}

@test "setup: migrate_old_config creates skill directory before migration" {
    run bash -c "grep -A20 '^migrate_old_config()' '$PROJECT_ROOT/bin/setup' | grep -q 'mkdir -p'"
    [ "$status" -eq 0 ]
}
