#!/usr/bin/env bats

# Tests for parse-review-arg.sh detector functions

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for tests that need consistent git state
    # This ensures tests work both locally and in CI (where we're in detached HEAD)
    TEST_GIT_DIR="$(mktemp -d)"

    # Install the gh stub before sourcing parse-review-arg.sh so a real `gh`
    # binary is never consulted for the base-resolution logic under test. It
    # must be installed first because a prepended PATH entry only takes
    # effect for lookups performed after this point.
    source "$PROJECT_ROOT/tests/helpers/gh-stub.bash"
    install_default_gh_stub

    # Source the script to get access to functions
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
}

teardown() {
    # Cleanup temporary git directory
    if [ -n "$TEST_GIT_DIR" ] && [ -d "$TEST_GIT_DIR" ]; then
        rm -rf "$TEST_GIT_DIR"
    fi
    remove_gh_stub_dir
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

# =============================================================================
# detect_learn_mode tests
# =============================================================================

@test "learn mode: LEARN_MODE is false by default" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    [ "$LEARN_MODE" = "false" ]
}

@test "learn mode: detect_learn_mode returns 1 when LEARN_MODE is false" {
    LEARN_MODE="false"
    arg=""
    file_pattern=""
    run detect_learn_mode
    [ "$status" -eq 1 ]
}

@test "learn mode: learn keyword sets LEARN_MODE" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "learn"
    [ "$LEARN_MODE" = "true" ]
}

@test "learn mode: batch mode with no argument" {
    LEARN_MODE="true"
    APPLY_MODE="false"
    arg=""
    file_pattern=""
    run detect_learn_mode
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"learn"'* ]]
    [[ "$output" == *'"learn_submode":"batch"'* ]]
}

@test "learn mode: single PR mode with number" {
    LEARN_MODE="true"
    APPLY_MODE="false"
    arg="123"
    file_pattern=""
    run detect_learn_mode
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"learn"'* ]]
    [[ "$output" == *'"learn_submode":"single"'* ]]
    [[ "$output" == *'"pr_number":"123"'* ]]
}

@test "learn mode: single PR mode with GitHub URL" {
    LEARN_MODE="true"
    APPLY_MODE="false"
    arg="https://github.com/haacked/review-code/pull/42"
    file_pattern=""
    run detect_learn_mode
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"learn"'* ]]
    [[ "$output" == *'"learn_submode":"single"'* ]]
    [[ "$output" == *'"pr_number":"42"'* ]]
    [[ "$output" == *'"pr_url":'* ]]
}

@test "learn mode: apply mode" {
    LEARN_MODE="true"
    APPLY_MODE="true"
    arg=""
    file_pattern=""
    run detect_learn_mode
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"learn"'* ]]
    [[ "$output" == *'"learn_submode":"apply"'* ]]
}

@test "learn mode: invalid argument returns error" {
    LEARN_MODE="true"
    APPLY_MODE="false"
    arg="invalid-argument"
    file_pattern=""
    run detect_learn_mode
    [ "$status" -eq 1 ]
    [[ "$output" == *'"error":'* ]]
}

@test "learn mode: learn 123 parses correctly" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "learn" "123"
    [ "$LEARN_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "learn mode: learn --apply parses correctly" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "learn" "--apply"
    [ "$LEARN_MODE" = "true" ]
    [ "$APPLY_MODE" = "true" ]
}

@test "learn mode: --force learn 123 parses correctly" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--force" "learn" "123"
    [ "$FORCE_MODE" = "true" ]
    [ "$LEARN_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "find + learn collision: find learn treats learn as target, not mode" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "find" "learn"
    [ "$FIND_MODE" = "true" ]
    [ "$LEARN_MODE" = "false" ]
    [ "$arg" = "learn" ]
}

@test "find + learn collision: find mode with learn branch name" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "find" "learn"
    # In find mode, 'learn' should be treated as a target (branch/ref name)
    [ "$FIND_MODE" = "true" ]
    [ "$LEARN_MODE" = "false" ]
}

# =============================================================================
# Overwrite / Append mode tests
# =============================================================================

@test "overwrite mode: OVERWRITE_MODE is false by default" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    [ "$OVERWRITE_MODE" = "false" ]
}

@test "append mode: APPEND_MODE is false by default" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    [ "$APPEND_MODE" = "false" ]
}

@test "overwrite mode: --overwrite sets OVERWRITE_MODE" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--overwrite" "123"
    [ "$OVERWRITE_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "append mode: --append sets APPEND_MODE" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--append" "123"
    [ "$APPEND_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "overwrite mode: --overwrite as second argument" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "123" "--overwrite"
    [ "$OVERWRITE_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "append mode: --append as second argument" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "123" "--append"
    [ "$APPEND_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "overwrite mode: build_json_output includes overwrite_mode when set" {
    file_pattern=""
    OVERWRITE_MODE="true"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"overwrite_mode":"true"'* ]]
}

@test "overwrite mode: build_json_output excludes overwrite_mode when false" {
    file_pattern=""
    OVERWRITE_MODE="false"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"overwrite_mode"'* ]]
}

@test "append mode: build_json_output includes append_mode when set" {
    file_pattern=""
    APPEND_MODE="true"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"append_mode":"true"'* ]]
}

@test "append mode: build_json_output excludes append_mode when false" {
    file_pattern=""
    APPEND_MODE="false"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"append_mode"'* ]]
}

@test "overwrite + append: mutually exclusive validation fails" {
    OVERWRITE_MODE="true"
    APPEND_MODE="true"
    run validate_overwrite_append_mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"mutually exclusive"* ]]
}

@test "overwrite + append: validation passes with only overwrite" {
    OVERWRITE_MODE="true"
    APPEND_MODE="false"
    run validate_overwrite_append_mode
    [ "$status" -eq 0 ]
}

@test "overwrite + append: validation passes with only append" {
    OVERWRITE_MODE="false"
    APPEND_MODE="true"
    run validate_overwrite_append_mode
    [ "$status" -eq 0 ]
}

@test "overwrite + append: validation passes with neither" {
    OVERWRITE_MODE="false"
    APPEND_MODE="false"
    run validate_overwrite_append_mode
    [ "$status" -eq 0 ]
}

@test "overwrite mode: combines with --force" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--force" "--overwrite" "123"
    [ "$FORCE_MODE" = "true" ]
    [ "$OVERWRITE_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "append mode: combines with --draft" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--draft" "--append" "123"
    [ "$DRAFT_MODE" = "true" ]
    [ "$APPEND_MODE" = "true" ]
    [ "$arg" = "123" ]
}

# =============================================================================
# Fix mode tests
# =============================================================================

@test "fix mode: FIX_MODE is false by default" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    [ "$FIX_MODE" = "false" ]
}

@test "fix mode: --fix sets FIX_MODE" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--fix" "123"
    [ "$FIX_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "fix mode: --fix as second argument" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "123" "--fix"
    [ "$FIX_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "fix mode: build_json_output includes fix_mode when set" {
    file_pattern=""
    FIX_MODE="true"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"fix_mode":"true"'* ]]
}

@test "fix mode: build_json_output excludes fix_mode when false" {
    file_pattern=""
    FIX_MODE="false"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"fix_mode"'* ]]
}

@test "fix mode: combines with --force and --draft" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--force" "--fix" "--draft" "123"
    [ "$FORCE_MODE" = "true" ]
    [ "$FIX_MODE" = "true" ]
    [ "$DRAFT_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "fix mode: validate_fix_mode passes when --fix is unset" {
    FIX_MODE="false"
    LEARN_MODE="true"
    run validate_fix_mode
    [ "$status" -eq 0 ]
}

@test "fix mode: validate_fix_mode rejects --fix with learn" {
    FIX_MODE="true"
    LEARN_MODE="true"
    FIND_MODE="false"
    run validate_fix_mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"not compatible with learn"* ]]
}

@test "fix mode: validate_fix_mode rejects --fix with find" {
    FIX_MODE="true"
    LEARN_MODE="false"
    FIND_MODE="true"
    run validate_fix_mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"not compatible with find"* ]]
}

@test "fix mode: validate_fix_mode passes for normal review" {
    FIX_MODE="true"
    LEARN_MODE="false"
    FIND_MODE="false"
    run validate_fix_mode
    [ "$status" -eq 0 ]
}

@test "fix mode: combines with --overwrite" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--fix" "--overwrite" "123"
    [ "$FIX_MODE" = "true" ]
    [ "$OVERWRITE_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "fix mode: combines with --append" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--fix" "--append" "123"
    [ "$FIX_MODE" = "true" ]
    [ "$APPEND_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "fix mode: --fix learn rejected via main script" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --fix learn 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not compatible with learn"* ]]
}

@test "fix mode: --fix find rejected via main script" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --fix find 123 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not compatible with find"* ]]
}

# =============================================================================
# Adversary mode tests
# =============================================================================

@test "adversary mode: ADVERSARY_MODE is empty by default" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    [ "$ADVERSARY_MODE" = "" ]
}

@test "adversary mode: --adversary:copilot sets ADVERSARY_MODE" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--adversary:copilot" "123"
    [ "$ADVERSARY_MODE" = "copilot" ]
    [ "$arg" = "123" ]
}

@test "adversary mode: --adversary:codex sets ADVERSARY_MODE" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--adversary:codex" "123"
    [ "$ADVERSARY_MODE" = "codex" ]
    [ "$arg" = "123" ]
}

@test "adversary mode: --adversary:copilot as second argument" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "123" "--adversary:copilot"
    [ "$ADVERSARY_MODE" = "copilot" ]
    [ "$arg" = "123" ]
}

@test "adversary mode: build_json_output includes adversary_mode when set" {
    file_pattern=""
    ADVERSARY_MODE="copilot"
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"adversary_mode":"copilot"'* ]]
}

@test "adversary mode: build_json_output excludes adversary_mode when unset" {
    file_pattern=""
    ADVERSARY_MODE=""
    run build_json_output "test" "key" "val"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"adversary_mode"'* ]]
}

@test "adversary mode: validate_adversary_mode passes when unset" {
    ADVERSARY_MODE=""
    ADVERSARY_CONFLICT="false"
    ADVERSARY_FLAG_SEEN="false"
    LEARN_MODE="true"
    run validate_adversary_mode
    [ "$status" -eq 0 ]
}

@test "adversary mode: --adversary: with no value is rejected" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--adversary:" "123"
    [ "$ADVERSARY_MODE" = "" ]
    [ "$ADVERSARY_FLAG_SEEN" = "true" ]
    run validate_adversary_mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"--adversary requires a value"* ]]
}

@test "adversary mode: --adversary: with no value is rejected via main script" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --adversary: 123 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--adversary requires a value"* ]]
}

@test "adversary mode: validate_adversary_mode rejects combining copilot and codex" {
    ADVERSARY_MODE="codex"
    ADVERSARY_CONFLICT="true"
    run validate_adversary_mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot combine multiple --adversary flags"* ]]
}

@test "adversary mode: validate_adversary_mode rejects an unknown engine" {
    ADVERSARY_MODE="bogus"
    ADVERSARY_CONFLICT="false"
    run validate_adversary_mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid --adversary value"* ]]
}

@test "adversary mode: validate_adversary_mode rejects --adversary:copilot with learn" {
    ADVERSARY_MODE="copilot"
    ADVERSARY_CONFLICT="false"
    LEARN_MODE="true"
    FIND_MODE="false"
    run validate_adversary_mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"not compatible with learn"* ]]
}

@test "adversary mode: validate_adversary_mode rejects --adversary:codex with find" {
    ADVERSARY_MODE="codex"
    ADVERSARY_CONFLICT="false"
    LEARN_MODE="false"
    FIND_MODE="true"
    run validate_adversary_mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"not compatible with find"* ]]
}

@test "adversary mode: validate_adversary_mode passes for normal review" {
    ADVERSARY_MODE="copilot"
    ADVERSARY_CONFLICT="false"
    LEARN_MODE="false"
    FIND_MODE="false"
    run validate_adversary_mode
    [ "$status" -eq 0 ]
}

@test "adversary mode: combines with --fix and --draft" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--adversary:codex" "--fix" "--draft" "123"
    [ "$ADVERSARY_MODE" = "codex" ]
    [ "$FIX_MODE" = "true" ]
    [ "$DRAFT_MODE" = "true" ]
    [ "$arg" = "123" ]
}

@test "adversary mode: --adversary:copilot --adversary:codex rejected via main script" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --adversary:copilot --adversary:codex 123 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot combine multiple --adversary flags"* ]]
}

@test "adversary mode: --adversary:copilot learn rejected via main script" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --adversary:copilot learn 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not compatible with learn"* ]]
}

@test "adversary mode: --adversary:codex find rejected via main script" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --adversary:codex find 123 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not compatible with find"* ]]
}

# =============================================================================
# get_base_branch tests
# =============================================================================

@test "get_base_branch: prefers origin/ ref when origin/HEAD is set" {
    setup_test_git_repo

    # Set origin/HEAD to point to main
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
    # Create origin/main ref (fake remote tracking branch)
    git update-ref refs/remotes/origin/main HEAD

    run get_base_branch
    [ "$status" -eq 0 ]
    [ "$output" = "origin/main" ]
}

@test "get_base_branch: uses closest-candidate fallback when origin/HEAD branch missing" {
    setup_test_git_repo

    # origin/HEAD points to a branch that doesn't exist as a remote ref
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/nonexistent 2>/dev/null || true
    git update-ref -d refs/remotes/origin/main 2>/dev/null || true

    # Falls through to closest-candidate logic; "main" is the only local candidate
    run get_base_branch
    [ "$status" -eq 0 ]
    [ "$output" = "main" ]
}

@test "get_base_branch: picks closest candidate when origin/HEAD not set" {
    setup_test_git_repo

    # Remove origin/HEAD
    git symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true

    # Create a feature branch with one commit ahead of main
    git checkout -q -b feature
    echo "feature" > feature.txt
    git add feature.txt
    git commit -q -m "Feature commit"

    # Create a "master" branch that's one commit behind
    git branch master HEAD~1 2>/dev/null || true

    # Both main and master are 1 commit away; "main" wins by iteration order
    run get_base_branch
    [ "$status" -eq 0 ]
    [ "$output" = "main" ]
}

@test "get_base_branch: prefers closer base over farther one" {
    setup_test_git_repo

    # Remove origin/HEAD so fallback logic kicks in
    git symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true

    # Make several commits on main
    for i in 1 2 3 4 5; do
        echo "commit $i" > "file$i.txt"
        git add "file$i.txt"
        git commit -q -m "Main commit $i"
    done

    # Create master pointing at current HEAD (latest)
    git branch master HEAD

    # Create feature branch with one more commit
    git checkout -q -b feature
    echo "feature" > feature.txt
    git add feature.txt
    git commit -q -m "Feature commit"

    # Reset main to root commit so it's far (6 commits away); master stays at HEAD~1 (1 away)
    local initial_commit
    initial_commit=$(git rev-list --max-parents=0 HEAD)
    git branch -f main "$initial_commit"
    run get_base_branch
    [ "$status" -eq 0 ]
    [ "$output" = "master" ]
}

# =============================================================================
# get_stack_parent tests
# =============================================================================

@test "get_stack_parent: returns nothing when no parent recorded" {
    setup_test_git_repo

    git checkout -q -b feature-a
    echo "a" > a.txt && git add a.txt && git commit -q -m "A"

    run get_stack_parent feature-a
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "get_stack_parent: reads branch.<name>.parent and prefers origin/ ref" {
    setup_test_git_repo

    git checkout -q -b parent-branch
    echo "p" > p.txt && git add p.txt && git commit -q -m "P"
    git update-ref refs/remotes/origin/parent-branch HEAD

    git checkout -q -b child-branch
    echo "c" > c.txt && git add c.txt && git commit -q -m "C"
    git config branch.child-branch.parent parent-branch

    # Run from main to ensure we're not querying gt about the current branch.
    git checkout -q main
    run get_stack_parent child-branch
    [ "$status" -eq 0 ]
    [ "$output" = "origin/parent-branch" ]
}

@test "get_stack_parent: falls back to local ref when origin/<parent> missing" {
    setup_test_git_repo

    git checkout -q -b parent-only-local
    echo "p" > p.txt && git add p.txt && git commit -q -m "P"

    git checkout -q -b child
    git config branch.child.parent parent-only-local

    git checkout -q main
    run get_stack_parent child
    [ "$status" -eq 0 ]
    [ "$output" = "parent-only-local" ]
}

@test "get_stack_parent: ignores parent when it equals the trunk" {
    setup_test_git_repo

    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
    git update-ref refs/remotes/origin/main HEAD

    git checkout -q -b feature
    git config branch.feature.parent main

    run get_stack_parent feature
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "get_stack_parent: ignores self-referential parent" {
    setup_test_git_repo

    git checkout -q -b loopy
    git config branch.loopy.parent loopy

    run get_stack_parent loopy
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# =============================================================================
# get_base_branch + stack parent integration
# =============================================================================

@test "get_base_branch: returns stack parent when target branch has one" {
    setup_test_git_repo

    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
    git update-ref refs/remotes/origin/main HEAD

    git checkout -q -b parent-branch
    echo "p" > p.txt && git add p.txt && git commit -q -m "P"
    git update-ref refs/remotes/origin/parent-branch HEAD

    git checkout -q -b child-branch
    echo "c" > c.txt && git add c.txt && git commit -q -m "C"
    git config branch.child-branch.parent parent-branch

    git checkout -q main
    run get_base_branch child-branch
    [ "$status" -eq 0 ]
    [ "$output" = "origin/parent-branch" ]
}

@test "get_base_branch: falls through to trunk when parent equals default branch" {
    setup_test_git_repo

    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
    git update-ref refs/remotes/origin/main HEAD

    git checkout -q -b feature
    git config branch.feature.parent main

    run get_base_branch feature
    [ "$status" -eq 0 ]
    [ "$output" = "origin/main" ]
}

# =============================================================================
# resolve_base_info / --parent override
# =============================================================================

@test "resolve_base_info: PARENT_OVERRIDE wins over computed base" {
    setup_test_git_repo

    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
    git update-ref refs/remotes/origin/main HEAD

    git checkout -q -b feature
    git config branch.feature.parent main

    PARENT_OVERRIDE="origin/some-other-branch"
    resolve_base_info feature
    [ "$RESOLVED_BASE_BRANCH" = "origin/some-other-branch" ]
    [ "$RESOLVED_BASE_SOURCE" = "parent-flag" ]
}

@test "resolve_base_info: empty PARENT_OVERRIDE delegates to detected base" {
    setup_test_git_repo

    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
    git update-ref refs/remotes/origin/main HEAD

    PARENT_OVERRIDE=""
    resolve_base_info
    [ "$RESOLVED_BASE_BRANCH" = "origin/main" ]
    [ "$RESOLVED_BASE_SOURCE" = "default" ]
}

# =============================================================================
# --parent flag parsing
# =============================================================================

@test "--parent: PARENT_OVERRIDE empty by default" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    [ "$PARENT_OVERRIDE" = "" ]
}

@test "--parent: separate-token form sets PARENT_OVERRIDE" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--parent" "main" "feature"
    [ "$PARENT_OVERRIDE" = "main" ]
    [ "$arg" = "feature" ]
}

@test "--parent: equals form sets PARENT_OVERRIDE" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--parent=origin/feat-x" "feature"
    [ "$PARENT_OVERRIDE" = "origin/feat-x" ]
    [ "$arg" = "feature" ]
}

@test "--parent: combines with --force" {
    source "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh" "--force" "--parent" "main" "feature"
    [ "$FORCE_MODE" = "true" ]
    [ "$PARENT_OVERRIDE" = "main" ]
    [ "$arg" = "feature" ]
}

@test "--parent: rejects flag-looking value via main script" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --parent --force feature 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--parent requires a value"* ]]
}

@test "--parent: rejects missing trailing value via main script" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --parent 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--parent requires a value"* ]]
}

@test "--parent: rejects empty value via equals form" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --parent= feature 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--parent requires a value"* ]]
}

@test "--parent: rejects empty quoted value via separate-token form" {
    run bash -c "bash '$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh' --parent '' feature 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--parent requires a value"* ]]
}

# =============================================================================
# PR-base resolution: fetch_open_prs_for_branch / detect_base_info /
# resolve_base_info / base_shares_history
#
# Precedence for branch-family modes: --parent > PR baseRefName > Graphite
# stack parent > default-branch logic. These tests build real parent/child
# branch fixtures with `setup_test_git_repo` and drive the gh lookup through
# the PATH-based stub installed in setup() (see tests/helpers/gh-stub.bash).
# =============================================================================

# Helper: build a parent-branch/child-branch fixture on top of
# setup_test_git_repo. parent-branch has an origin/ tracking ref; child-branch
# forks from it. Leaves the repo checked out on main.
setup_parent_child_fixture() {
    setup_test_git_repo

    git checkout -q -b parent-branch
    echo "p" > p.txt && git add p.txt && git commit -q -m "P"
    git update-ref refs/remotes/origin/parent-branch HEAD

    git checkout -q -b child-branch
    echo "c" > c.txt && git add c.txt && git commit -q -m "C"

    git checkout -q main
}

@test "detect_base_info: PR base found and used, prefers origin/ ref" {
    setup_parent_child_fixture
    stub_gh_pr_list '[{"number":7,"baseRefName":"parent-branch"}]'

    resolve_base_info child-branch
    [ "$RESOLVED_BASE_BRANCH" = "origin/parent-branch" ]
    [ "$RESOLVED_BASE_SOURCE" = "pr-base" ]
    [ -z "${RESOLVED_BASE_DEGRADED:-}" ]

    run get_base_branch child-branch
    [ "$status" -eq 0 ]
    [ "$output" = "origin/parent-branch" ]
}

@test "detect_base_info: baseRefName equal to default branch falls through to trunk" {
    setup_parent_child_fixture

    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2> /dev/null || true
    git update-ref refs/remotes/origin/main "$(git rev-parse main)"

    stub_gh_pr_list '[{"number":3,"baseRefName":"main"}]'

    resolve_base_info child-branch
    [ "$RESOLVED_BASE_BRANCH" = "origin/main" ]
    [ "$RESOLVED_BASE_SOURCE" = "default" ]
    [ -z "${RESOLVED_BASE_DEGRADED:-}" ]
}

@test "detect_base_info: no open PR falls through to Graphite stack parent" {
    setup_parent_child_fixture
    # Default stub already returns "[]" for gh pr list.

    git config branch.child-branch.parent parent-branch

    resolve_base_info child-branch
    [ "$RESOLVED_BASE_BRANCH" = "origin/parent-branch" ]
    [ "$RESOLVED_BASE_SOURCE" = "stack-parent" ]
}

@test "detect_base_info: gh failure degrades and falls through to default" {
    setup_parent_child_fixture
    stub_gh_pr_list --fail
    # No branch.<name>.parent recorded, so this also exercises the
    # stack-parent -> default fallthrough.

    resolve_base_info child-branch
    [ "$RESOLVED_BASE_SOURCE" = "default" ]
    [ "$RESOLVED_BASE_DEGRADED" = "true" ]

    arg="child-branch"
    file_pattern=""
    run detect_git_ref
    [ "$status" -eq 0 ]
    [[ "$output" == *'"base_lookup_degraded":"true"'* ]]
    [[ "$output" == *'"base_source":"default"'* ]]
}

@test "detect_base_info: gh failure rescued by stack parent is not degraded" {
    setup_parent_child_fixture
    stub_gh_pr_list --fail
    git config branch.child-branch.parent parent-branch

    resolve_base_info child-branch
    [ "$RESOLVED_BASE_BRANCH" = "origin/parent-branch" ]
    [ "$RESOLVED_BASE_SOURCE" = "stack-parent" ]
    [ -z "${RESOLVED_BASE_DEGRADED:-}" ]
}

@test "detect_base_info: PR base takes precedence over Graphite stack parent" {
    setup_parent_child_fixture

    git checkout -q -b third-branch
    echo "t" > t.txt && git add t.txt && git commit -q -m "T"
    git checkout -q main

    git config branch.child-branch.parent third-branch
    stub_gh_pr_list '[{"number":9,"baseRefName":"parent-branch"}]'

    resolve_base_info child-branch
    [ "$RESOLVED_BASE_BRANCH" = "origin/parent-branch" ]
    [ "$RESOLVED_BASE_SOURCE" = "pr-base" ]
}

@test "detect_base_info: PR base with unrelated history is rejected" {
    setup_parent_child_fixture

    git checkout -q --orphan orphan-base
    git rm -rf . -q
    echo "o" > o.txt && git add o.txt && git commit -q -m "O"
    git update-ref refs/remotes/origin/orphan-base HEAD
    git checkout -q main

    stub_gh_pr_list '[{"number":4,"baseRefName":"orphan-base"}]'

    resolve_base_info child-branch 2> "${TEST_GIT_DIR}/stderr.log"
    [ "$RESOLVED_BASE_SOURCE" = "default" ]
    grep -q "no common history" "${TEST_GIT_DIR}/stderr.log"
}

@test "detect_base_info: diverged-but-related PR base is still used" {
    setup_parent_child_fixture

    # Advance parent-branch past the point child-branch forked from, and
    # update its origin/ ref accordingly. child-branch and parent-branch
    # still share history through their common ancestor.
    git checkout -q parent-branch
    echo "p2" > p2.txt && git add p2.txt && git commit -q -m "P2"
    git update-ref refs/remotes/origin/parent-branch HEAD
    git checkout -q main

    stub_gh_pr_list '[{"number":8,"baseRefName":"parent-branch"}]'

    resolve_base_info child-branch 2> "${TEST_GIT_DIR}/stderr.log"
    [ "$RESOLVED_BASE_BRANCH" = "origin/parent-branch" ]
    [ "$RESOLVED_BASE_SOURCE" = "pr-base" ]
    grep -q "merge-base" "${TEST_GIT_DIR}/stderr.log"
}

@test "resolve_base_info: --parent override wins over PR base and makes no gh calls" {
    setup_parent_child_fixture
    stub_gh_pr_list '[{"number":7,"baseRefName":"parent-branch"}]'

    PARENT_OVERRIDE="origin/some-other-branch"
    : > "$GH_STUB_CALLS"

    resolve_base_info child-branch
    [ "$RESOLVED_BASE_SOURCE" = "parent-flag" ]
    [ "$RESOLVED_BASE_BRANCH" = "origin/some-other-branch" ]
    [ ! -s "$GH_STUB_CALLS" ]
}

@test "detect_no_arg: memoizes the gh lookup for base resolution and associated-PR detection" {
    setup_parent_child_fixture
    git checkout -q child-branch

    stub_gh_pr_list '[{"number":11,"baseRefName":"parent-branch"}]'
    : > "$GH_STUB_CALLS"

    arg=""
    file_pattern=""
    run detect_no_arg
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"branch"'* ]]
    [[ "$output" == *'"base_branch":"origin/parent-branch"'* ]]
    [[ "$output" == *'"base_source":"pr-base"'* ]]
    [[ "$output" == *'"associated_pr":"11"'* ]]

    [ "$(wc -l < "$GH_STUB_CALLS" | tr -d ' ')" -eq 1 ]
}

@test "detect_no_arg: multiple open PRs keeps first-PR-wins and a consistent base" {
    setup_parent_child_fixture
    git checkout -q child-branch

    stub_gh_pr_list '[{"number":5,"baseRefName":"parent-branch"},{"number":6,"baseRefName":"main"}]'

    arg=""
    file_pattern=""
    run detect_no_arg
    [ "$status" -eq 0 ]
    [[ "$output" == *'"associated_pr":"5"'* ]]
    [[ "$output" == *'"base_branch":"origin/parent-branch"'* ]]
    [[ "$output" == *"Multiple open PRs"* ]]
}

@test "parse-review-arg.sh: errexit regression under live execution (no origin/HEAD)" {
    setup_test_git_repo
    git symbolic-ref --delete refs/remotes/origin/HEAD 2> /dev/null || true

    git checkout -q -b live-feature-branch
    echo "feature" > feature.txt
    git add feature.txt
    git commit -q -m "Feature commit"

    run bash "$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mode":"branch"'* ]]
}

@test "detect_git_ref: clean no-PR lookup emits no base_lookup_degraded key" {
    setup_parent_child_fixture
    # Default stub: gh pr list returns "[]", exit 0 (clean, no PRs).

    arg="child-branch"
    file_pattern=""
    run detect_git_ref
    [ "$status" -eq 0 ]
    ! echo "$output" | jq -e 'has("base_lookup_degraded")' > /dev/null
}
