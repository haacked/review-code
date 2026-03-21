#!/usr/bin/env bats
# Tests for git-file-history.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for testing
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init
    git config commit.gpgsign false
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
    rm -rf "$TEST_REPO"
}

# =============================================================================
# JSON output structure tests
# =============================================================================

@test "git-file-history.sh: outputs valid JSON" {
    run bash -c 'echo "file.txt" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.' > /dev/null
}

@test "git-file-history.sh: empty input produces empty JSON object" {
    run bash -c 'echo "" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '. == {}' > /dev/null
}

@test "git-file-history.sh: includes expected fields" {
    run bash -c 'echo "file.txt" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    echo "$output" | jq -e '."file.txt" | has("recent_commits") and has("recent_authors") and has("last_modified") and has("high_churn")' > /dev/null
}

# =============================================================================
# Commit counting tests
# =============================================================================

@test "git-file-history.sh: counts recent commits correctly" {
    # Add 3 more commits to file.txt (total 4 including initial)
    for i in 1 2 3; do
        echo "change $i" >> file.txt
        git add file.txt
        git commit -m "Change $i"
    done

    run bash -c 'echo "file.txt" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    local count
    count=$(echo "$output" | jq '."file.txt".recent_commits')
    [ "$count" -eq 4 ]
}

@test "git-file-history.sh: counts unique authors correctly" {
    # Add commits from different authors
    git config user.name "Author Two"
    echo "change 2" >> file.txt
    git add file.txt
    git commit -m "Change by author 2"

    git config user.name "Author Three"
    echo "change 3" >> file.txt
    git add file.txt
    git commit -m "Change by author 3"

    run bash -c 'echo "file.txt" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    local authors
    authors=$(echo "$output" | jq '."file.txt".recent_authors')
    [ "$authors" -eq 3 ]
}

# =============================================================================
# High churn threshold tests
# =============================================================================

@test "git-file-history.sh: flags high churn at 3+ authors" {
    # Add commits from 2 more authors (total 3)
    git config user.name "Author Two"
    echo "change 2" >> file.txt
    git add file.txt
    git commit -m "Change by author 2"

    git config user.name "Author Three"
    echo "change 3" >> file.txt
    git add file.txt
    git commit -m "Change by author 3"

    run bash -c 'echo "file.txt" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    local churn
    churn=$(echo "$output" | jq '."file.txt".high_churn')
    [ "$churn" = "true" ]
}

@test "git-file-history.sh: flags high churn at 10+ commits" {
    # Add 9 more commits (total 10 including initial)
    for i in $(seq 1 9); do
        echo "change $i" >> file.txt
        git add file.txt
        git commit -m "Change $i"
    done

    run bash -c 'echo "file.txt" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    local churn
    churn=$(echo "$output" | jq '."file.txt".high_churn')
    [ "$churn" = "true" ]
}

@test "git-file-history.sh: no high churn below thresholds" {
    # Just 1 commit, 1 author — below both thresholds
    run bash -c 'echo "file.txt" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    local churn
    churn=$(echo "$output" | jq '."file.txt".high_churn')
    [ "$churn" = "false" ]
}

# =============================================================================
# Edge case tests
# =============================================================================

@test "git-file-history.sh: handles file not in git history" {
    run bash -c 'echo "nonexistent.txt" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    local commits
    commits=$(echo "$output" | jq '."nonexistent.txt".recent_commits')
    [ "$commits" -eq 0 ]

    local churn
    churn=$(echo "$output" | jq '."nonexistent.txt".high_churn')
    [ "$churn" = "false" ]

    local last_modified
    last_modified=$(echo "$output" | jq '."nonexistent.txt".last_modified')
    [ "$last_modified" = "null" ]
}

@test "git-file-history.sh: handles multiple files" {
    echo "second" > second.txt
    git add second.txt
    git commit -m "Add second file"

    run bash -c 'printf "file.txt\nsecond.txt\n" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    # Both files should be in output
    echo "$output" | jq -e '."file.txt"' > /dev/null
    echo "$output" | jq -e '."second.txt"' > /dev/null
}

@test "git-file-history.sh: last_modified is a date string for tracked files" {
    run bash -c 'echo "file.txt" | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    local last_modified
    last_modified=$(echo "$output" | jq -r '."file.txt".last_modified')
    # Should be a date in YYYY-MM-DD format
    [[ "$last_modified" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "git-file-history.sh: caps at 50 files" {
    # Create 55 files
    for i in $(seq 1 55); do
        echo "content" > "file_${i}.txt"
    done
    git add .
    git commit -m "Add many files"

    # Send all 55 file paths
    run bash -c 'for i in $(seq 1 55); do echo "file_${i}.txt"; done | "$PROJECT_ROOT/skills/review-code/scripts/git-file-history.sh"'
    [ "$status" -eq 0 ]

    # Should have at most 50 entries
    local count
    count=$(echo "$output" | jq 'keys | length')
    [ "$count" -eq 50 ]
}
