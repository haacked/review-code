#!/usr/bin/env bats

# Tests for parse-review-arg.sh detector functions

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for tests that need consistent git state
    # This ensures tests work both locally and in CI (where we're in detached HEAD)
    TEST_GIT_DIR="$(mktemp -d)"

    # Source the script to get access to functions
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
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
    git config commit.gpgsign false
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial commit on main branch
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"

    # Ensure we're on main branch
    git checkout -q -b main 2>/dev/null || git checkout -q main

    # Set up a fake remote origin (needed for some git commands to work)
    # Use a fake GitHub URL to prevent git commands from failing
    git remote add origin https://github.com/test/test.git 2>/dev/null || true
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

@test "build_json_output: includes find_mode when set" {
    file_pattern=""
    FIND_MODE="true"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"find_mode":"true"'* ]]
}

@test "build_json_output: excludes find_mode when false" {
    file_pattern=""
    FIND_MODE="false"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"find_mode"'* ]]
}

# =============================================================================
# Find mode tests
# =============================================================================

@test "find mode: FIND_MODE is false by default" {
    # Re-source to reset FIND_MODE
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    [ "$FIND_MODE" = "false" ]
}

@test "find mode: detect_pr works with find mode PR number" {
    # Simulate find mode argument shifting (find 123 → arg=123)
    FIND_MODE="true"
    arg="123"
    file_pattern=""
    run detect_pr
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"pr"'* ]]
    [[ "$output" == *'"pr_number":"123"'* ]]
    [[ "$output" == *'"find_mode":"true"'* ]]
}

@test "find mode: detect_area_keyword works with find mode" {
    FIND_MODE="true"
    arg="security"
    file_pattern=""
    run detect_area_keyword
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"area"'* ]]
    [[ "$output" == *'"find_mode":"true"'* ]]
}

@test "find mode: detect_git_range works with find mode" {
    FIND_MODE="true"
    arg="HEAD~1..HEAD"
    file_pattern=""
    run detect_git_range
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"range"'* ]]
    [[ "$output" == *'"find_mode":"true"'* ]]
}

@test "find mode: detect_git_ref works with find mode" {
    setup_test_git_repo
    git checkout -q -b feature-branch

    FIND_MODE="true"
    arg="main"
    file_pattern=""
    run detect_git_ref
    [ "$status" -eq 0 ]
    [[ "$output" == *'"find_mode":"true"'* ]]
}

@test "find mode: detect_no_arg returns branch on base branch with no changes" {
    setup_test_git_repo
    # We're on main branch with no uncommitted changes

    FIND_MODE="true"
    arg=""
    file_pattern=""
    run detect_no_arg
    [ "$status" -eq 0 ]
    # Should NOT error, should return branch mode with scope "find"
    [[ "$output" == *'"mode":"branch"'* ]]
    [[ "$output" == *'"scope":"find"'* ]]
    [[ "$output" == *'"find_mode":"true"'* ]]
}

@test "find mode: detect_no_arg errors on base branch without find mode" {
    setup_test_git_repo
    # We're on main branch with no uncommitted changes

    FIND_MODE="false"
    arg=""
    file_pattern=""
    run detect_no_arg
    [ "$status" -eq 1 ]
    [[ "$output" == *"No changes to review"* ]]
}

# =============================================================================
# Force mode tests
# =============================================================================

@test "force mode: FORCE_MODE is false by default" {
    # Re-source with no args to reset FORCE_MODE
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    [ "$FORCE_MODE" = "false" ]
}

@test "force mode: --force as first argument sets FORCE_MODE" {
    # Source with --force as first arg, 123 as second
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--force" "123"
    [ "$FORCE_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "force mode: -f as first argument sets FORCE_MODE" {
    # Source with -f as first arg
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "-f" "main"
    [ "$FORCE_MODE" = "true" ]
    [ "$arg" = "main" ]
}

@test "force mode: --force as second argument sets FORCE_MODE" {
    # Source with target first, then --force
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "main" "--force"
    [ "$FORCE_MODE" = "true" ]
    [ "$arg" = "main" ]
}

@test "force mode: -f as second argument sets FORCE_MODE" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "123" "-f"
    [ "$FORCE_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "force mode: --force with file pattern preserves pattern" {
    # /review-code --force main "*.py"
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--force" "main" "*.py"
    [ "$FORCE_MODE" = "true" ]
    [ "$arg" = "main" ]
    [ "$file_pattern" = "*.py" ]
}

@test "force mode: target --force pattern preserves both" {
    # /review-code main --force "*.py"
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "main" "--force" "*.py"
    [ "$FORCE_MODE" = "true" ]
    [ "$arg" = "main" ]
    [ "$file_pattern" = "*.py" ]
}

@test "force mode: build_json_output includes force_mode when set" {
    file_pattern=""
    FORCE_MODE="true"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"force_mode":"true"'* ]]
}

@test "force mode: build_json_output excludes force_mode when false" {
    file_pattern=""
    FORCE_MODE="false"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"force_mode"'* ]]
}

@test "force mode: detect_no_arg skips prompt on feature branch with changes" {
    setup_test_git_repo
    git checkout -q -b feature-branch
    echo "change" >> file.txt  # Create uncommitted change

    FORCE_MODE="true"
    arg=""
    file_pattern=""
    run detect_no_arg
    [ "$status" -eq 0 ]
    # Should return local mode (not prompt) when force is true
    [[ "$output" == *'"mode":"local"'* ]]
    [[ "$output" == *'"scope":"uncommitted"'* ]]
}

@test "force mode: detect_no_arg prompts without force on feature branch with changes" {
    setup_test_git_repo
    git checkout -q -b feature-branch
    echo "change" >> file.txt  # Create uncommitted change

    FORCE_MODE="false"
    arg=""
    file_pattern=""
    run detect_no_arg
    [ "$status" -eq 0 ]
    # Should return prompt mode when force is false
    [[ "$output" == *'"mode":"prompt"'* ]]
    [[ "$output" == *'"has_uncommitted":"true"'* ]]
}

# =============================================================================
# Force + Find mode combination tests
# =============================================================================

@test "force + find: --force find 123 parses correctly" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--force" "find" "123"
    [ "$FORCE_MODE" = "true" ]
    [ "$FIND_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "force + find: find --force 123 parses correctly" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "find" "--force" "123"
    [ "$FORCE_MODE" = "true" ]
    [ "$FIND_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "force + find: -f find main parses correctly" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "-f" "find" "main"
    [ "$FORCE_MODE" = "true" ]
    [ "$FIND_MODE" = "true" ]
    [ "$arg" = "main" ]
}
