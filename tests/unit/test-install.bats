#!/usr/bin/env bats
# Tests for install.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
}

# =============================================================================
# Configuration tests
# =============================================================================

@test "install.sh: defines REPO_URL" {
    run bash -c "grep -q 'REPO_URL=' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "install.sh: REPO_URL points to haacked/review-code" {
    run bash -c "grep 'REPO_URL=' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"haacked/review-code"* ]]
}

@test "install.sh: defines default BRANCH as main" {
    run bash -c "grep 'BRANCH=' '$PROJECT_ROOT/install.sh' | grep -q 'main'"
    [ "$status" -eq 0 ]
}

@test "install.sh: BRANCH respects environment variable" {
    run bash -c "grep 'BRANCH=' '$PROJECT_ROOT/install.sh' | grep -q '\${BRANCH:-'"
    [ "$status" -eq 0 ]
}

@test "install.sh: uses set -euo pipefail" {
    run bash -c "head -20 '$PROJECT_ROOT/install.sh' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Output function tests
# =============================================================================

@test "install.sh: defines info function" {
    run bash -c "grep -q '^info()' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "install.sh: defines warn function" {
    run bash -c "grep -q '^warn()' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "install.sh: defines error function" {
    run bash -c "grep -q '^error()' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "install.sh: info uses GREEN color" {
    run bash -c "grep -A2 '^info()' '$PROJECT_ROOT/install.sh' | grep -q 'GREEN'"
    [ "$status" -eq 0 ]
}

@test "install.sh: warn uses YELLOW color" {
    run bash -c "grep -A2 '^warn()' '$PROJECT_ROOT/install.sh' | grep -q 'YELLOW'"
    [ "$status" -eq 0 ]
}

@test "install.sh: error uses RED color" {
    run bash -c "grep -A2 '^error()' '$PROJECT_ROOT/install.sh' | grep -q 'RED'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Main function implementation tests
# =============================================================================

@test "install.sh: main function exists" {
    run bash -c "grep -q '^main()' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "install.sh: creates temp directory with mktemp" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'mktemp -d'"
    [ "$status" -eq 0 ]
}

@test "install.sh: sets up cleanup trap" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'trap'"
    [ "$status" -eq 0 ]
}

@test "install.sh: trap removes temp directory" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep 'trap' | grep -q 'rm -rf'"
    [ "$status" -eq 0 ]
}

@test "install.sh: clones git repository" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'git clone'"
    [ "$status" -eq 0 ]
}

@test "install.sh: uses shallow clone (--depth 1)" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep 'git clone' | grep -q -- '--depth 1'"
    [ "$status" -eq 0 ]
}

@test "install.sh: clones specified branch" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep 'git clone' | grep -q -- '--branch'"
    [ "$status" -eq 0 ]
}

@test "install.sh: calls bin/setup" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'bin/setup'"
    [ "$status" -eq 0 ]
}

@test "install.sh: checks git clone exit status" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'if ! git clone'"
    [ "$status" -eq 0 ]
}

@test "install.sh: exits on git clone failure" {
    run bash -c "grep -A3 'if ! git clone' '$PROJECT_ROOT/install.sh' | grep -q 'exit 1'"
    [ "$status" -eq 0 ]
}

@test "install.sh: checks bin/setup exit status" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'if ! bin/setup'"
    [ "$status" -eq 0 ]
}

@test "install.sh: exits on setup failure" {
    run bash -c "grep -A3 'if ! bin/setup' '$PROJECT_ROOT/install.sh' | grep -q 'exit 1'"
    [ "$status" -eq 0 ]
}

@test "install.sh: suppresses git clone output" {
    run bash -c "grep 'git clone' '$PROJECT_ROOT/install.sh' | grep -q '/dev/null'"
    [ "$status" -eq 0 ]
}

@test "install.sh: changes to temp directory" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -B2 'bin/setup' | grep -q 'cd'"
    [ "$status" -eq 0 ]
}

@test "install.sh: cleanup via EXIT trap" {
    run bash -c "grep 'trap' '$PROJECT_ROOT/install.sh' | grep -q 'EXIT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Output message tests
# =============================================================================

@test "install.sh: displays installer banner" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'Review-Code Installer'"
    [ "$status" -eq 0 ]
}

@test "install.sh: displays download message" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'Downloading'"
    [ "$status" -eq 0 ]
}

@test "install.sh: shows branch being downloaded" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'branch:'"
    [ "$status" -eq 0 ]
}

@test "install.sh: displays running installer message" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'Running installer'"
    [ "$status" -eq 0 ]
}

@test "install.sh: displays cleanup message" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'Cleaned up'"
    [ "$status" -eq 0 ]
}

@test "install.sh: displays completion message" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'Installation complete'"
    [ "$status" -eq 0 ]
}

@test "install.sh: shows usage instructions" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q '/review-code'"
    [ "$status" -eq 0 ]
}

@test "install.sh: shows update instructions" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'To update'"
    [ "$status" -eq 0 ]
}

@test "install.sh: shows uninstall instructions" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'To uninstall'"
    [ "$status" -eq 0 ]
}

@test "install.sh: references uninstall script path" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'uninstall-review-code.sh'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Security tests
# =============================================================================

@test "install.sh: uses HTTPS for repository URL" {
    run bash -c "grep 'REPO_URL=' '$PROJECT_ROOT/install.sh' | grep -q 'https://'"
    [ "$status" -eq 0 ]
}

@test "install.sh: quotes TEMP_DIR in trap" {
    run bash -c "grep 'trap' '$PROJECT_ROOT/install.sh' | grep -E \"('|\\\").*TEMP_DIR\""
    [ "$status" -eq 0 ]
}

@test "install.sh: quotes TEMP_DIR in git clone" {
    run bash -c "grep 'git clone' '$PROJECT_ROOT/install.sh' | grep -E \"('|\\\").*TEMP_DIR\""
    [ "$status" -eq 0 ]
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "install.sh: has correct shebang" {
    run bash -c "head -1 '$PROJECT_ROOT/install.sh' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "install.sh: has usage comment" {
    run bash -c "head -10 '$PROJECT_ROOT/install.sh' | grep -q 'Usage:'"
    [ "$status" -eq 0 ]
}

@test "install.sh: documents curl installation" {
    run bash -c "head -10 '$PROJECT_ROOT/install.sh' | grep -q 'curl'"
    [ "$status" -eq 0 ]
}

@test "install.sh: documents custom branch usage" {
    run bash -c "head -10 '$PROJECT_ROOT/install.sh' | grep -q 'BRANCH='"
    [ "$status" -eq 0 ]
}

@test "install.sh: calls main function at end" {
    run bash -c "tail -5 '$PROJECT_ROOT/install.sh' | grep -q 'main'"
    [ "$status" -eq 0 ]
}

@test "install.sh: passes arguments to main" {
    run bash -c "tail -5 '$PROJECT_ROOT/install.sh' | grep 'main' | grep -q '\"\$@\"'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Color definition tests
# =============================================================================

@test "install.sh: defines GREEN color variable" {
    run bash -c "grep -q '^GREEN=' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "install.sh: defines YELLOW color variable" {
    run bash -c "grep -q '^YELLOW=' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "install.sh: defines RED color variable" {
    run bash -c "grep -q '^RED=' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "install.sh: defines NC (no color) variable" {
    run bash -c "grep -q '^NC=' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Workflow tests
# =============================================================================

@test "install.sh: TEMP_DIR variable used multiple times" {
    local count
    count=$(grep -o 'TEMP_DIR' "$PROJECT_ROOT/install.sh" | wc -l | tr -d ' ')
    [ "$count" -ge 3 ]
}

@test "install.sh: error function called on failures" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'error'"
    [ "$status" -eq 0 ]
}

@test "install.sh: info function called for status updates" {
    run bash -c "grep -A50 '^main()' '$PROJECT_ROOT/install.sh' | grep -q 'info'"
    [ "$status" -eq 0 ]
}
