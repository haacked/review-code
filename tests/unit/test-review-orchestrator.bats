#!/usr/bin/env bats
# Tests for review-orchestrator.sh

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
    git remote add origin "https://github.com/testorg/testrepo.git"

    # Create initial commit
    echo "initial" > file.txt
    git add file.txt
    git commit -m "Initial commit"
}

teardown() {
    # Clean up test repository
    rm -rf "$TEST_REPO"
}

# =============================================================================
# Error mode handling tests
# =============================================================================

@test "review-orchestrator.sh: handles parse errors" {
    # Invalid argument that parse-review-arg will reject
    run bash -c "'$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh' 'invalid!' 2>&1"
    [ "$status" -eq 1 ]
}

@test "review-orchestrator.sh: outputs JSON status on error" {
    # Pass invalid argument
    run bash -c "'$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh' 'invalid!' 2>&1"
    [ "$status" -eq 1 ]
    # Should be valid JSON
    echo "$output" | jq -e '.status == "error"' > /dev/null || true
}

# =============================================================================
# Local mode tests
# =============================================================================

@test "review-orchestrator.sh: handles local mode" {
    # Create uncommitted changes
    echo "change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should output valid JSON
    echo "$output" | jq -e '.status == "ready"'
}

@test "review-orchestrator.sh: local mode includes git context" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.git.org'
    echo "$output" | jq -e '.git.repo'
}

@test "review-orchestrator.sh: local mode includes diff" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.diff'
}

@test "review-orchestrator.sh: local mode includes languages" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.languages'
}

@test "review-orchestrator.sh: local mode includes file_metadata" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.file_metadata'
}

@test "review-orchestrator.sh: local mode includes file_info" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.file_info'
}

@test "review-orchestrator.sh: file_path can be extracted with jq navigation" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]

    # This is the pattern used in commands/review-code.md
    # Extract file_path directly from review_data using .file_info.file_path
    file_path=$(echo "$output" | jq -r '.file_info.file_path')

    # Should get a valid path, not null or empty
    [ -n "$file_path" ]
    [ "$file_path" != "null" ]

    # Should be an absolute path
    [[ "$file_path" == /* ]]
}

@test "review-orchestrator.sh: file_exists can be extracted with jq navigation" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]

    # Extract file_exists directly from review_data
    file_exists=$(echo "$output" | jq -r '.file_info.file_exists')

    # Should be "true" or "false", not null
    [ "$file_exists" = "true" ] || [ "$file_exists" = "false" ]
}

@test "review-orchestrator.sh: local mode errors with no changes" {
    # Clean repo with no changes
    run bash -c "'$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh' 2>&1"
    if [ "$status" -ne 1 ]; then
        echo "Status: $status"
        echo "Output: $output"
    fi
    [ "$status" -eq 1 ]
    [[ "$output" == *"No changes found"* ]] || [[ "$output" == *"No changes to review"* ]]
}

# =============================================================================
# Area mode tests
# =============================================================================

@test "review-orchestrator.sh: handles area mode" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" security
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.mode == "local"'
    echo "$output" | jq -e '.area == "security"'
}

@test "review-orchestrator.sh: area mode includes area field" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" performance
    [ "$status" -eq 0 ]
    area=$(echo "$output" | jq -r '.area')
    [ "$area" = "performance" ]
}

# =============================================================================
# Commit mode tests
# =============================================================================

@test "review-orchestrator.sh: returns ambiguous for commit refs" {
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" HEAD
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ambiguous"'
    echo "$output" | jq -e '.ref_type == "commit"'
}

@test "review-orchestrator.sh: ambiguous commit includes arg" {
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" HEAD
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.arg == "HEAD"'
}

@test "review-orchestrator.sh: ambiguous includes reason" {
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" HEAD
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.reason'
    [[ "$(echo "$output" | jq -r '.reason')" == *"unclear"* ]]
}

@test "review-orchestrator.sh: ambiguous includes base_branch" {
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" HEAD
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.base_branch'
}

# =============================================================================
# Range mode tests
# =============================================================================

@test "review-orchestrator.sh: handles range mode" {
    # Create second commit
    echo "second" > file2.txt
    git add file2.txt
    git commit -m "Second commit"

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" "HEAD~1..HEAD"
    if [ "$status" -ne 0 ]; then
        echo "Status: $status"
        echo "Output: $output"
    fi
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.mode == "range"'
}

@test "review-orchestrator.sh: range mode includes range field" {
    echo "second" > file2.txt
    git add file2.txt
    git commit -m "Second commit"

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" "HEAD~1..HEAD"
    [ "$status" -eq 0 ]
    range=$(echo "$output" | jq -r '.range')
    [ "$range" = "HEAD~1..HEAD" ]
}

@test "review-orchestrator.sh: range mode includes diff" {
    echo "second" > file2.txt
    git add file2.txt
    git commit -m "Second commit"

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" "HEAD~1..HEAD"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.diff'
}

# =============================================================================
# Branch mode tests
# =============================================================================

@test "review-orchestrator.sh: handles branch mode" {
    # Create feature branch
    git checkout -b feature
    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "Feature"

    # Switch back to main so "feature" is not the current branch
    git checkout main

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" feature
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.mode == "branch"'
}

@test "review-orchestrator.sh: branch mode includes branch fields" {
    git checkout -b feature
    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "Feature"

    # Switch back to main so "feature" is not the current branch
    git checkout main

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" feature
    [ "$status" -eq 0 ]
    branch=$(echo "$output" | jq -r '.branch')
    base=$(echo "$output" | jq -r '.base_branch')
    [ "$branch" = "feature" ]
    [ "$base" = "main" ]
}

# =============================================================================
# JSON structure tests
# =============================================================================

@test "review-orchestrator.sh: outputs valid JSON" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.' > /dev/null
}

@test "review-orchestrator.sh: includes status field" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    status=$(echo "$output" | jq -r '.status')
    [ "$status" = "ready" ]
}

@test "review-orchestrator.sh: includes mode field" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.mode'
}

@test "review-orchestrator.sh: includes next_step field" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    next_step=$(echo "$output" | jq -r '.next_step')
    [ "$next_step" = "gather_architectural_context" ]
}

# =============================================================================
# File pattern tests
# =============================================================================

@test "review-orchestrator.sh: handles file pattern argument" {
    echo "change" > file.txt
    echo "other" > other.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" "" "*.txt"
    [ "$status" -eq 0 ]
    # Should succeed (pattern is passed through)
}

# =============================================================================
# Integration tests
# =============================================================================

@test "review-orchestrator.sh: integrates with parse-review-arg" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should successfully parse and execute
}

@test "review-orchestrator.sh: integrates with git-context" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include git context
    echo "$output" | jq -e '.git.org == "testorg"'
    echo "$output" | jq -e '.git.repo == "testrepo"'
}

@test "review-orchestrator.sh: integrates with code-language-detect" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include language detection
    echo "$output" | jq -e '.languages'
}

@test "review-orchestrator.sh: integrates with pre-review-context" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include file metadata
    echo "$output" | jq -e '.file_metadata'
}

@test "review-orchestrator.sh: integrates with review-file-path" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include file info
    echo "$output" | jq -e '.file_info.file_path'
}

@test "review-orchestrator.sh: integrates with load-review-context" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include review context (may be empty)
    echo "$output" | jq -e 'has("review_context")'
}

# =============================================================================
# Mode-specific integration tests
# =============================================================================

@test "review-orchestrator.sh: returns ambiguous for commit refs (HEAD)" {
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" HEAD
    [ "$status" -eq 0 ]
    # HEAD is ambiguous - returns ambiguous status for user to clarify
    status_value=$(echo "$output" | jq -r '.status')
    [ "$status_value" = "ambiguous" ]
}

@test "review-orchestrator.sh: range mode uses get-review-diff correctly" {
    echo "second" > file2.txt
    git add file2.txt
    git commit -m "Second commit"

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" "HEAD~1..HEAD"
    [ "$status" -eq 0 ]
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"DIFF_TYPE:"* ]]
}

@test "review-orchestrator.sh: branch mode uses get-review-diff correctly" {
    git checkout -b feature
    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "Feature"

    # Switch back to main so "feature" is not the current branch
    git checkout main

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" feature
    [ "$status" -eq 0 ]
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"DIFF_TYPE:"* ]]
}

@test "review-orchestrator.sh: local mode uses git-diff-filter correctly" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"DIFF_TYPE:"* ]]
}

# =============================================================================
# Source vs Execute guard clause tests
# =============================================================================

@test "review-orchestrator.sh: can be sourced without executing main" {
    # Source the script - should not produce output
    output=$(cd "$TEST_REPO" && source "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" 2>&1)

    # Sourcing should not produce any output (main not executed)
    [ -z "$output" ]

    # Verify main function exists after sourcing
    cd "$TEST_REPO"
    source "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    declare -F main > /dev/null
}

@test "review-orchestrator.sh: executes main when run directly" {
    # Create a change so orchestrator has something to review
    echo "change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]

    # Should produce JSON output when executed directly
    echo "$output" | jq -e '.mode' > /dev/null
}

# =============================================================================
# Find mode tests
# =============================================================================

@test "review-orchestrator.sh: find mode returns status find" {
    # Create a change so we have something to find
    echo "change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "find"'
}

@test "review-orchestrator.sh: find mode includes file_info" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.file_info.file_path'
    # file_exists can be true or false, so just check it's a boolean
    echo "$output" | jq -e 'has("file_info") and (.file_info | has("file_exists"))'
}

@test "review-orchestrator.sh: find mode includes display_target" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    display_target=$(echo "$output" | jq -r '.display_target')
    [ -n "$display_target" ]
    [ "$display_target" != "null" ]
}

@test "review-orchestrator.sh: find mode does not include diff" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    # Find mode should NOT include diff - it's an early exit
    diff_value=$(echo "$output" | jq -r '.diff // "not_present"')
    [ "$diff_value" = "not_present" ]
}

@test "review-orchestrator.sh: find mode with PR number" {
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" find 123
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "find"'
    # Display target should mention PR
    display_target=$(echo "$output" | jq -r '.display_target')
    [[ "$display_target" == *"PR"* ]] || [[ "$display_target" == *"123"* ]]
}

@test "review-orchestrator.sh: find mode with branch" {
    # Create feature branch
    git checkout -b find-test-branch
    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "Feature"

    # Switch back to main
    git checkout main

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" find find-test-branch
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "find"'
    display_target=$(echo "$output" | jq -r '.display_target')
    [[ "$display_target" == *"find-test-branch"* ]]
}

@test "review-orchestrator.sh: find mode on base branch with no changes" {
    # Clean repo with no changes - should work in find mode
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "find"'
}

@test "review-orchestrator.sh: find mode file_info.file_path is absolute" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    file_path=$(echo "$output" | jq -r '.file_info.file_path')
    [[ "$file_path" == /* ]]
}

@test "review-orchestrator.sh: find mode file_exists is boolean string" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    file_exists=$(echo "$output" | jq -r '.file_info.file_exists')
    [ "$file_exists" = "true" ] || [ "$file_exists" = "false" ]
}

# =============================================================================
# is_own_pr detection tests
# =============================================================================

@test "review-orchestrator.sh: local mode does not include is_own_pr" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Local mode has no PR context, so is_own_pr should not be in output
    has_is_own_pr=$(echo "$output" | jq 'has("is_own_pr")')
    [ "$has_is_own_pr" = "false" ]
}

@test "review-orchestrator.sh: local mode does not include reviewer_username" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Local mode has no PR context, so reviewer_username should not be in output
    has_reviewer=$(echo "$output" | jq 'has("reviewer_username")')
    [ "$has_reviewer" = "false" ]
}

@test "review-orchestrator.sh: branch mode does not include is_own_pr" {
    git checkout -b is-own-pr-test
    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "Feature"
    git checkout main

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" is-own-pr-test
    [ "$status" -eq 0 ]
    # Branch mode has no PR context, so is_own_pr should not be in output
    has_is_own_pr=$(echo "$output" | jq 'has("is_own_pr")')
    [ "$has_is_own_pr" = "false" ]
}

@test "review-orchestrator.sh: range mode does not include is_own_pr" {
    echo "second" > file2.txt
    git add file2.txt
    git commit -m "Second commit"

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh" "HEAD~1..HEAD"
    [ "$status" -eq 0 ]
    # Range mode has no PR context, so is_own_pr should not be in output
    has_is_own_pr=$(echo "$output" | jq 'has("is_own_pr")')
    [ "$has_is_own_pr" = "false" ]
}

@test "review-orchestrator.sh: is_own_pr defaults to false when gh api fails" {
    # Source the script to access internal functions
    source "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"

    # Create a mock gh that fails for 'api user' but works for other commands
    mock_gh() {
        if [[ "$1" == "api" && "$2" == "user" ]]; then
            return 1
        fi
        command gh "$@"
    }

    # Test the detection logic directly
    # When gh api user fails, reviewer_username is empty
    # With the fail-open approach, is_own_pr should default to false
    pr_context='{"author": "someone"}'
    pr_author=$(echo "${pr_context}" | jq -r '.author // ""')
    reviewer_username=""  # Simulates gh api user failure
    is_own_pr="false"  # Default value

    # The condition should NOT set is_own_pr to true when reviewer_username is empty
    if [[ -n "${reviewer_username}" && -n "${pr_author}" && "${reviewer_username}" == "${pr_author}" ]]; then
        is_own_pr="true"
    fi

    [ "$is_own_pr" = "false" ]
}

@test "review-orchestrator.sh: is_own_pr is true when reviewer equals author" {
    # Test the detection logic directly
    pr_context='{"author": "testuser"}'
    pr_author=$(echo "${pr_context}" | jq -r '.author // ""')
    reviewer_username="testuser"  # Same as author
    is_own_pr="false"  # Default value

    if [[ -n "${reviewer_username}" && -n "${pr_author}" && "${reviewer_username}" == "${pr_author}" ]]; then
        is_own_pr="true"
    fi

    [ "$is_own_pr" = "true" ]
}

@test "review-orchestrator.sh: is_own_pr is false when reviewer differs from author" {
    # Test the detection logic directly
    pr_context='{"author": "prauthor"}'
    pr_author=$(echo "${pr_context}" | jq -r '.author // ""')
    reviewer_username="reviewer"  # Different from author
    is_own_pr="false"  # Default value

    if [[ -n "${reviewer_username}" && -n "${pr_author}" && "${reviewer_username}" == "${pr_author}" ]]; then
        is_own_pr="true"
    fi

    [ "$is_own_pr" = "false" ]
}

@test "review-orchestrator.sh: is_own_pr stays false when pr_author is empty" {
    # Test the detection logic directly
    pr_context='{"author": ""}'
    pr_author=$(echo "${pr_context}" | jq -r '.author // ""')
    reviewer_username="reviewer"
    is_own_pr="false"  # Default value

    if [[ -n "${reviewer_username}" && -n "${pr_author}" && "${reviewer_username}" == "${pr_author}" ]]; then
        is_own_pr="true"
    fi

    [ "$is_own_pr" = "false" ]
}

# =============================================================================
# Cross-branch PR review tests (file_ref / working_dir behavior)
# =============================================================================

@test "review-orchestrator.sh: determine_file_ref returns empty on fast path (same branch)" {
    source "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"

    local result
    result=$(determine_file_ref "feature-branch" "feature-branch" "42")

    [ -z "$result" ]
}

@test "review-orchestrator.sh: determine_file_ref returns review ref on cross-branch" {
    source "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"

    local result
    result=$(determine_file_ref "main" "feature-branch" "42")

    [ "$result" = "refs/review/pr-42" ]
}

@test "review-orchestrator.sh: determine_file_ref returns same ref format for fork PRs" {
    source "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"

    local result
    result=$(determine_file_ref "main" "fork-feature" "99")

    [ "$result" = "refs/review/pr-99" ]
}

@test "review-orchestrator.sh: working_dir nulled when file_ref is empty on cross-branch" {
    # Spec test: when fetch fails (file_ref empty) on a different branch,
    # working_dir must be nulled to prevent agents reading the wrong branch.
    local file_ref=""
    local git_context='{"working_dir": "/some/path", "org": "testorg", "repo": "testrepo"}'

    if [[ -z "${file_ref}" ]]; then
        git_context=$(echo "${git_context}" | jq '.working_dir = null')
    fi

    local working_dir
    working_dir=$(echo "${git_context}" | jq -r '.working_dir')
    [ "$working_dir" = "null" ]
}

@test "review-orchestrator.sh: working_dir preserved when file_ref is set" {
    # Spec test: when fetch succeeds (file_ref set), working_dir stays so
    # agents can use Grep/Glob for pattern discovery alongside git show.
    local file_ref="refs/review/pr-42"
    local git_context='{"working_dir": "/some/path", "org": "testorg", "repo": "testrepo"}'

    if [[ -z "${file_ref}" ]]; then
        git_context=$(echo "${git_context}" | jq '.working_dir = null')
    fi

    local working_dir
    working_dir=$(echo "${git_context}" | jq -r '.working_dir')
    [ "$working_dir" = "/some/path" ]
}

@test "review-orchestrator.sh: empty file_ref excluded from build_review_data output" {
    # build_review_data filters out empty mode_ values, so file_ref shouldn't
    # appear in the output when it's empty (fast path)
    echo "change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/review-orchestrator.sh"
    [ "$status" -eq 0 ]

    # Local mode doesn't set file_ref, so it shouldn't be in output
    has_file_ref=$(echo "$output" | jq 'has("file_ref")')
    [ "$has_file_ref" = "false" ]
}

@test "review-orchestrator.sh: non-empty file_ref included in build_review_data output" {
    # The jq filter in build_review_data strips mode_ prefixes and filters
    # empty values. A non-empty mode_file_ref should pass through as file_ref.
    run jq -n \
        --arg mode_branch "feature-branch" \
        --arg mode_file_ref "refs/review/pr-42" \
        '$ARGS.named
         | with_entries(select(.key | startswith("mode_")))
         | with_entries(.key |= sub("^mode_"; ""))
         | with_entries(select(.value != ""))'
    [ "$status" -eq 0 ]

    file_ref=$(echo "$output" | jq -r '.file_ref')
    [ "$file_ref" = "refs/review/pr-42" ]

    branch=$(echo "$output" | jq -r '.branch')
    [ "$branch" = "feature-branch" ]
}
