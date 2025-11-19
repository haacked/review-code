#!/usr/bin/env bats
# Tests for git-context.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for testing
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial commit
    echo "initial" > file.txt
    git add file.txt
    git commit -m "Initial commit"

    # Add a remote to extract org/repo
    git remote add origin "https://github.com/testorg/testrepo.git"
}

teardown() {
    # Clean up test repository
    rm -rf "$TEST_REPO"
}

# =============================================================================
# Repository validation tests
# =============================================================================

@test "git-context.sh: fails outside git repository" {
    cd /tmp
    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 1 ]
}

# =============================================================================
# JSON output structure tests
# =============================================================================

@test "git-context.sh: outputs valid JSON" {
    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    # Validate JSON structure
    echo "$output" | jq -e '.' > /dev/null
}

@test "git-context.sh: includes org field" {
    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    org=$(echo "$output" | jq -r '.org')
    [ "$org" = "testorg" ]
}

@test "git-context.sh: includes repo field" {
    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    repo=$(echo "$output" | jq -r '.repo')
    [ "$repo" = "testrepo" ]
}

@test "git-context.sh: includes branch field" {
    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    branch=$(echo "$output" | jq -r '.branch')
    [ -n "$branch" ]
}

@test "git-context.sh: includes commit field" {
    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    commit=$(echo "$output" | jq -r '.commit')
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] # Valid git SHA
}

@test "git-context.sh: includes working_dir field" {
    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    working_dir=$(echo "$output" | jq -r '.working_dir')
    [ "$working_dir" = "$TEST_REPO" ]
}

@test "git-context.sh: includes has_changes field" {
    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    has_changes=$(echo "$output" | jq -r '.has_changes')
    [ "$has_changes" = "true" ] || [ "$has_changes" = "false" ]
}

# =============================================================================
# has_changes detection tests
# =============================================================================

@test "git-context.sh: detects no changes in clean repo" {
    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    has_changes=$(echo "$output" | jq -r '.has_changes')
    [ "$has_changes" = "false" ]
}

@test "git-context.sh: detects unstaged changes" {
    echo "modified" > file.txt

    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    has_changes=$(echo "$output" | jq -r '.has_changes')
    [ "$has_changes" = "true" ]
}

@test "git-context.sh: detects staged changes" {
    echo "staged" > file.txt
    git add file.txt

    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    has_changes=$(echo "$output" | jq -r '.has_changes')
    [ "$has_changes" = "true" ]
}

@test "git-context.sh: detects untracked files" {
    echo "untracked" > newfile.txt

    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    has_changes=$(echo "$output" | jq -r '.has_changes')
    [ "$has_changes" = "true" ]
}

# =============================================================================
# Branch detection tests
# =============================================================================

@test "git-context.sh: detects current branch" {
    git checkout -b feature-branch

    run "$PROJECT_ROOT/lib/git-context.sh"
    [ "$status" -eq 0 ]

    branch=$(echo "$output" | jq -r '.branch')
    [ "$branch" = "feature-branch" ]
}
