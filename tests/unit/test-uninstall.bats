#!/usr/bin/env bats
# Tests for uninstall.sh
#
# Note: The uninstall script no longer uses config files.
# It uses fixed paths under ~/.claude/skills/review-code/

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

# =============================================================================
# Script removal tests
# =============================================================================

@test "uninstall.sh: removes skill directory" {
    run bash -c "grep -A30 'remove_skill()' '$PROJECT_ROOT/uninstall.sh' | grep -q 'skills/review-code'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: uses rm -rf for skill directory" {
    run bash -c "grep -A30 'remove_skill()' '$PROJECT_ROOT/uninstall.sh' | grep 'skills/review-code' | grep -q 'rm -rf'"
    [ "$status" -eq 0 ]
}

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

@test "uninstall.sh: uses fixed SKILL_DIR path" {
    run bash -c "grep -q 'SKILL_DIR=\"\${CLAUDE_DIR}/skills/review-code\"' '$PROJECT_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
}

@test "uninstall.sh: uses fixed REVIEWS_DIR path" {
    run bash -c "grep -q 'REVIEWS_DIR=\"\${SKILL_DIR}/reviews\"' '$PROJECT_ROOT/uninstall.sh'"
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
