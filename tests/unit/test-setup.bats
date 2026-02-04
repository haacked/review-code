#!/usr/bin/env bats
# Tests for bin/setup
#
# Note: The setup script no longer uses config files.
# It installs everything to ~/.claude/skills/review-code/ with fixed paths.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
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

@test "setup: has cleanup_old_config function" {
    run bash -c "grep -q '^cleanup_old_config()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has smart merge functions" {
    run bash -c "grep -q '^merge_markdown_sections()' '$PROJECT_ROOT/bin/setup'"
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
    run bash -c "grep -A200 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'languages'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context creates frameworks directory" {
    run bash -c "grep -A200 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'frameworks'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context creates orgs directory" {
    run bash -c "grep -A200 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'orgs'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context uses smart merge" {
    run bash -c "grep -A200 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'merge_markdown_sections'"
    [ "$status" -eq 0 ]
}

@test "setup: install_context compares file checksums" {
    run bash -c "grep -A200 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'get_file_checksum'"
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

@test "setup: install_skill creates reviews directory" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'reviews'"
    [ "$status" -eq 0 ]
}

@test "setup: install_skill creates learnings directory" {
    run bash -c "grep -A80 'install_skill()' '$PROJECT_ROOT/bin/setup' | grep -q 'learnings'"
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

@test "setup: main calls cleanup_old_config" {
    run bash -c "grep -A100 '^main()' '$PROJECT_ROOT/bin/setup' | grep -q 'cleanup_old_config'"
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
# Smart merge tests
# =============================================================================

@test "setup: has get_section_headers function" {
    run bash -c "grep -q '^get_section_headers()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has has_section function" {
    run bash -c "grep -q '^has_section()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: has extract_section function" {
    run bash -c "grep -q '^extract_section()' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: merge_markdown_sections uses get_section_headers" {
    run bash -c "grep -A30 '^merge_markdown_sections()' '$PROJECT_ROOT/bin/setup' | grep -q 'get_section_headers'"
    [ "$status" -eq 0 ]
}

@test "setup: merge_markdown_sections uses has_section" {
    run bash -c "grep -A30 '^merge_markdown_sections()' '$PROJECT_ROOT/bin/setup' | grep -q 'has_section'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Installation path tests
# =============================================================================

@test "setup: uses SKILL_DIR under ~/.claude/skills/review-code" {
    run bash -c "grep -q 'SKILL_DIR=\"\${CLAUDE_DIR}/skills/review-code\"' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -eq 0 ]
}

@test "setup: context is installed to skill directory" {
    run bash -c "grep -A10 'install_context()' '$PROJECT_ROOT/bin/setup' | grep -q 'SKILL_DIR.*context'"
    [ "$status" -eq 0 ]
}

@test "setup: no longer uses .env config file" {
    # Verify setup doesn't create .env files anymore
    run bash -c "grep -q 'create_config' '$PROJECT_ROOT/bin/setup'"
    [ "$status" -ne 0 ]
}

@test "setup: cleans up deprecated config files" {
    run bash -c "grep -A20 'cleanup_old_config()' '$PROJECT_ROOT/bin/setup' | grep -q '.env'"
    [ "$status" -eq 0 ]
}
