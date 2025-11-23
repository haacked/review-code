#!/usr/bin/env bats

# Tests for parse-review-arg.sh detector functions

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for tests that need consistent git state
    # This ensures tests work both locally and in CI (where we're in detached HEAD)
    TEST_GIT_DIR="$(mktemp -d)"

    # Source the script to get access to functions
    source "$PROJECT_ROOT/lib/parse-review-arg.sh"
}

teardown() {
    # Cleanup temporary git directory
    if [ -n "$TEST_GIT_DIR" ] && [ -d "$TEST_GIT_DIR" ]; then
        rm -rf "$TEST_GIT_DIR"
    fi
}

# Helper: Setup a minimal git repository in TEST_GIT_DIR
setup_test_git_repo() {
    cd "$TEST_GIT_DIR"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial commit on main branch
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"

    # Ensure we're on main branch
    git checkout -q -b main 2>/dev/null || git checkout -q main
}

# Helper to reset globals between tests
reset_globals() {
    arg=""
    file_pattern=""
}

# =============================================================================
# detect_area_keyword tests
# =============================================================================

@test "detect_area_keyword: identifies security keyword" {
    arg="security"
    file_pattern=""
    run detect_area_keyword
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"area"'* ]]
    [[ "$output" == *'"area":"security"'* ]]
}

@test "detect_area_keyword: identifies performance keyword" {
    arg="performance"
    file_pattern=""
    run detect_area_keyword
    [ "$status" -eq 0 ]
    [[ "$output" == *'"area":"performance"'* ]]
}

@test "detect_area_keyword: identifies all six keywords" {
    for keyword in security performance maintainability testing compatibility architecture; do
        arg="$keyword"
        file_pattern=""
        run detect_area_keyword
        [ "$status" -eq 0 ]
        [[ "$output" == *"\"area\":\"$keyword\""* ]]
    done
}

@test "detect_area_keyword: includes file_pattern when provided" {
    arg="security"
    file_pattern="**/*.sh"
    run detect_area_keyword
    [ "$status" -eq 0 ]
    [[ "$output" == *'"file_pattern":"**/*.sh"'* ]]
}

@test "detect_area_keyword: returns 1 for non-keyword" {
    arg="invalid"
    file_pattern=""
    run detect_area_keyword
    [ "$status" -eq 1 ]
}

@test "detect_area_keyword: returns 1 for empty arg" {
    arg=""
    file_pattern=""
    run detect_area_keyword
    [ "$status" -eq 1 ]
}

# =============================================================================
# detect_pr tests
# =============================================================================

@test "detect_pr: identifies PR number" {
    arg="123"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"pr"'* ]]
    [[ "$output" == *'"pr_number":"123"'* ]]
}

@test "detect_pr: identifies large PR number" {
    arg="99999"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"pr_number":"99999"'* ]]
}

@test "detect_pr: identifies GitHub PR URL" {
    arg="https://github.com/haacked/review-code/pull/42"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"pr"'* ]]
    [[ "$output" == *'"pr_url":'* ]]
}

@test "detect_pr: includes file_pattern when provided" {
    arg="123"
    file_pattern="**/*.js"
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"file_pattern":"**/*.js"'* ]]
}

@test "detect_pr: returns 1 for non-PR" {
    arg="abc123"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 1 ]
}

@test "detect_pr: returns 1 for non-GitHub URL" {
    arg="https://gitlab.com/org/repo/merge_requests/1"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 1 ]
}

@test "detect_pr: returns 1 for empty arg" {
    arg=""
    file_pattern=""
    run detect_pr
    [ "$status" -eq 1 ]
}

# =============================================================================
# detect_git_range tests
# =============================================================================

@test "detect_git_range: identifies valid range" {
    arg="HEAD~1..HEAD"
    file_pattern=""
    run detect_git_range
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"range"'* ]]
    [[ "$output" == *'"start_ref":"HEAD~1"'* ]]
    [[ "$output" == *'"end_ref":"HEAD"'* ]]
}

@test "detect_git_range: identifies two-dot range" {
    # Use a range that exists without needing to create branches
    arg="HEAD~1..HEAD"
    file_pattern=""
    run detect_git_range
    [ "$status" -eq 0 ]
    [[ "$output" == *'"range":"HEAD~1..HEAD"'* ]]
}

@test "detect_git_range: includes file_pattern when provided" {
    arg="HEAD~1..HEAD"
    file_pattern="**/*.ts"
    run detect_git_range
    [ "$status" -eq 0 ]
    [[ "$output" == *'"file_pattern":"**/*.ts"'* ]]
}

@test "detect_git_range: exits with error for invalid start ref" {
    arg="invalid123..HEAD"
    file_pattern=""
    run detect_git_range
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid start ref"* ]]
}

@test "detect_git_range: exits with error for invalid end ref" {
    arg="HEAD..invalid456"
    file_pattern=""
    run detect_git_range
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid end ref"* ]]
}

@test "detect_git_range: returns 1 for non-range" {
    arg="main"
    file_pattern=""
    run detect_git_range
    [ "$status" -eq 1 ]
}

@test "detect_git_range: returns 1 for empty arg" {
    arg=""
    file_pattern=""
    run detect_git_range
    [ "$status" -eq 1 ]
}

# =============================================================================
# detect_git_ref tests
# =============================================================================

@test "detect_git_ref: identifies branch" {
    # Setup a test git repo with known state (not detached HEAD)
    setup_test_git_repo

    # Create a feature branch so "main" is not the current branch
    git checkout -q -b feature-branch

    arg="main"
    file_pattern=""
    # When main is NOT current branch: should return branch mode
    run detect_git_ref
    [ "$status" -eq 0 ]
    # Should have "branch" field with value "main" (not ambiguous since we're on feature-branch)
    [[ "$output" == *'"branch":"main"'* ]]
}

@test "detect_git_ref: identifies commit hash" {
    arg="HEAD~1"
    file_pattern=""
    run detect_git_ref
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":'* ]]
}

@test "detect_git_ref: includes file_pattern when provided" {
    arg="HEAD"
    file_pattern="**/*.py"
    run detect_git_ref
    [ "$status" -eq 0 ]
    [[ "$output" == *'"file_pattern":"**/*.py"'* ]]
}

@test "detect_git_ref: returns 1 for invalid ref" {
    arg="invalid-ref-that-does-not-exist"
    file_pattern=""
    run detect_git_ref
    [ "$status" -eq 1 ]
}

@test "detect_git_ref: returns 1 for empty arg" {
    arg=""
    file_pattern=""
    run detect_git_ref
    [ "$status" -eq 1 ]
}

# =============================================================================
# build_json_output tests
# =============================================================================

@test "build_json_output: creates simple JSON" {
    file_pattern=""
    run build_json_output "test" "key1" "value1"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"test"'* ]]
    [[ "$output" == *'"key1":"value1"'* ]]
}

@test "build_json_output: creates JSON with multiple pairs" {
    file_pattern=""
    run build_json_output "branch" "branch" "main" "base_branch" "master"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"branch":"main"'* ]]
    [[ "$output" == *'"base_branch":"master"'* ]]
}

@test "build_json_output: includes file_pattern when set" {
    file_pattern="**/*.go"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"file_pattern":"**/*.go"'* ]]
}

@test "build_json_output: produces valid JSON" {
    file_pattern=""
    run build_json_output "test" "key1" "val1" "key2" "val2"
    [ "$status" -eq 0 ]
    # Validate JSON by piping to jq
    echo "$output" | jq . > /dev/null
}
