#!/usr/bin/env bats
# Tests for git-diff-context.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for testing
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial commit on main branch
    echo "initial" > file.txt
    git add file.txt
    git commit -m "Initial commit"
}

teardown() {
    # Clean up test repository
    rm -rf "$TEST_REPO"
}

# =============================================================================
# Repository validation tests
# =============================================================================

@test "git-diff-context.sh: fails outside git repository" {
    cd /tmp
    run "$PROJECT_ROOT/lib/git-diff-context.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not in a git repository"* ]]
}

# =============================================================================
# get_main_branch tests
# =============================================================================

@test "git-diff-context.sh: detects main branch" {
    # We're already on main from setup
    run bash -c "source '$PROJECT_ROOT/lib/git-diff-context.sh' && get_main_branch"
    [ "$status" -eq 0 ]
    [ "$output" = "main" ]
}

@test "git-diff-context.sh: detects master branch" {
    # Rename main to master
    git branch -m main master
    run bash -c "source '$PROJECT_ROOT/lib/git-diff-context.sh' && get_main_branch"
    [ "$status" -eq 0 ]
    [ "$output" = "master" ]
}

@test "git-diff-context.sh: defaults to main if neither exists" {
    # Create repository without standard branches
    TEST_REPO2=$(mktemp -d)
    cd "$TEST_REPO2"
    git init
    git checkout -b feature
    run bash -c "source '$PROJECT_ROOT/lib/git-diff-context.sh' && get_main_branch"
    [ "$status" -eq 0 ]
    [ "$output" = "main" ]
    rm -rf "$TEST_REPO2"
}

# =============================================================================
# Priority order tests
# =============================================================================

@test "git-diff-context.sh: prioritizes staged changes" {
    # Create staged changes
    echo "staged" > file.txt
    git add file.txt

    run "$PROJECT_ROOT/lib/git-diff-context.sh" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: staged"* ]]
}

@test "git-diff-context.sh: shows unstaged when no staged changes" {
    # Create unstaged changes
    echo "unstaged" > file.txt

    run "$PROJECT_ROOT/lib/git-diff-context.sh" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: unstaged"* ]]
}

@test "git-diff-context.sh: shows branch changes when no local changes" {
    # Create a feature branch with changes
    git checkout -b feature
    echo "feature change" > file.txt
    git add file.txt
    git commit -m "Feature change"

    run "$PROJECT_ROOT/lib/git-diff-context.sh" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: branch"* ]]
}

@test "git-diff-context.sh: fails when no changes found" {
    # Clean repository with no changes
    run "$PROJECT_ROOT/lib/git-diff-context.sh" 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIFF_TYPE: none"* ]]
    [[ "$output" == *"No changes found"* ]]
}

# =============================================================================
# Metadata output tests
# =============================================================================

@test "git-diff-context.sh: outputs metadata to stderr" {
    echo "test" > file.txt
    git add file.txt

    # Capture stderr separately
    run bash -c "$PROJECT_ROOT/lib/git-diff-context.sh 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE:"* ]]
}

@test "git-diff-context.sh: outputs diff to stdout" {
    echo "test change" > file.txt
    git add file.txt

    # Capture stdout separately
    run bash -c "$PROJECT_ROOT/lib/git-diff-context.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"diff --git"* ]]
}

# =============================================================================
# Branch name in metadata tests
# =============================================================================

@test "git-diff-context.sh: includes branch name in metadata" {
    git checkout -b feature
    echo "change" > file.txt
    git add file.txt
    git commit -m "Change"

    run bash -c "$PROJECT_ROOT/lib/git-diff-context.sh 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"compared to main"* ]] || [[ "$output" == *"compared to master"* ]]
}
