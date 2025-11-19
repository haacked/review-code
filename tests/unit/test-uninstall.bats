#!/usr/bin/env bats
# Tests for uninstall.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
}

# =============================================================================
# Core security tests - Safe config loading
# =============================================================================

@test "uninstall.sh: does not use 'source' for config loading" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/uninstall.sh' | grep -v '^#' | grep -q '^[[:space:]]*source '"
    [ "$status" -ne 0 ]
}

@test "uninstall.sh: validates config key format with regex" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/uninstall.sh' | grep -q '\[A-Z_\]\[A-Z0-9_\]'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: uses case statement for safe variable assignment" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'case.*in'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: load_config_safely checks file ownership" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'file_owner'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: load_config_safely checks world-writable permissions" {
    run bash -c "grep -A50 'load_config_safely()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'world-writable'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Function existence tests
# =============================================================================

@test "uninstall.sh: has remove_commands function" {
    run bash -c "grep -q '^remove_commands()' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: has remove_agents function" {
    run bash -c "grep -q '^remove_agents()' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: has remove_scripts function" {
    run bash -c "grep -q '^remove_scripts()' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: has remove_context_files function" {
    run bash -c "grep -q '^remove_context_files()' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: has remove_config function" {
    run bash -c "grep -q '^remove_config()' '$PROJECT_ROOT/uninstall.sh'"
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

# =============================================================================
# Script removal tests
# =============================================================================

@test "uninstall.sh: removes review-code directory" {
    run bash -c "grep -A20 'remove_scripts()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'bin/review-code'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: uses rm -rf for review-code directory" {
    run bash -c "grep -A20 'remove_scripts()' '$PROJECT_ROOT/uninstall.sh' | grep 'review-code' | grep -q 'rm -rf'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: removes uninstall script itself" {
    run bash -c "grep -A50 'remove_scripts()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'uninstall-review-code.sh'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# User interaction tests
# =============================================================================

@test "uninstall.sh: prompts before removing context files" {
    run bash -c "grep -A20 'remove_context_files()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'read -p'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: prompts before removing config" {
    run bash -c "grep -A20 'remove_config()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'read -p'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: mentions preserving reviews" {
    run bash -c "grep -A20 'remove_context_files()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'reviews will be preserved'"
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

@test "uninstall.sh: main calls remove_commands" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'remove_commands'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: main calls remove_agents" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'remove_agents'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: main calls remove_scripts" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'remove_scripts'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: main calls remove_context_files" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'remove_context_files'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: main calls remove_config" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'remove_config'"
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
