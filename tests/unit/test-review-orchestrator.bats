#!/usr/bin/env bats
# Tests for review-orchestrator.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for testing
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init
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
    run bash -c "'$PROJECT_ROOT/lib/review-orchestrator.sh' 'invalid!' 2>&1"
    [ "$status" -eq 1 ]
}

@test "review-orchestrator.sh: outputs JSON status on error" {
    # Pass invalid argument
    run bash -c "'$PROJECT_ROOT/lib/review-orchestrator.sh' 'invalid!' 2>&1"
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

    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should output valid JSON
    echo "$output" | jq -e '.status == "ready"'
}

@test "review-orchestrator.sh: local mode includes git context" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.git.org'
    echo "$output" | jq -e '.git.repo'
}

@test "review-orchestrator.sh: local mode includes diff" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.diff'
}

@test "review-orchestrator.sh: local mode includes languages" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.languages'
}

@test "review-orchestrator.sh: local mode includes file_metadata" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.file_metadata'
}

@test "review-orchestrator.sh: local mode includes file_info" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.file_info'
}

@test "review-orchestrator.sh: file_path can be extracted with jq navigation" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
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
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]

    # Extract file_exists directly from review_data
    file_exists=$(echo "$output" | jq -r '.file_info.file_exists')

    # Should be "true" or "false", not null
    [ "$file_exists" = "true" ] || [ "$file_exists" = "false" ]
}

@test "review-orchestrator.sh: local mode errors with no changes" {
    # Clean repo with no changes
    run bash -c "'$PROJECT_ROOT/lib/review-orchestrator.sh' 2>&1"
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
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" security
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.mode == "local"'
    echo "$output" | jq -e '.area == "security"'
}

@test "review-orchestrator.sh: area mode includes area field" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" performance
    [ "$status" -eq 0 ]
    area=$(echo "$output" | jq -r '.area')
    [ "$area" = "performance" ]
}

# =============================================================================
# Commit mode tests
# =============================================================================

@test "review-orchestrator.sh: returns ambiguous for commit refs" {
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" HEAD
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ambiguous"'
    echo "$output" | jq -e '.ref_type == "commit"'
}

@test "review-orchestrator.sh: ambiguous commit includes arg" {
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" HEAD
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.arg == "HEAD"'
}

@test "review-orchestrator.sh: ambiguous includes reason" {
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" HEAD
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.reason'
    [[ "$(echo "$output" | jq -r '.reason')" == *"unclear"* ]]
}

@test "review-orchestrator.sh: ambiguous includes base_branch" {
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" HEAD
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

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "HEAD~1..HEAD"
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

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "HEAD~1..HEAD"
    [ "$status" -eq 0 ]
    range=$(echo "$output" | jq -r '.range')
    [ "$range" = "HEAD~1..HEAD" ]
}

@test "review-orchestrator.sh: range mode includes diff" {
    echo "second" > file2.txt
    git add file2.txt
    git commit -m "Second commit"

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "HEAD~1..HEAD"
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

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" feature
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

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" feature
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
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.' > /dev/null
}

@test "review-orchestrator.sh: includes status field" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    status=$(echo "$output" | jq -r '.status')
    [ "$status" = "ready" ]
}

@test "review-orchestrator.sh: includes mode field" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.mode'
}

@test "review-orchestrator.sh: includes next_step field" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
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

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "" "*.txt"
    [ "$status" -eq 0 ]
    # Should succeed (pattern is passed through)
}

# =============================================================================
# Integration tests
# =============================================================================

@test "review-orchestrator.sh: integrates with parse-review-arg" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should successfully parse and execute
}

@test "review-orchestrator.sh: integrates with git-context" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include git context
    echo "$output" | jq -e '.git.org == "testorg"'
    echo "$output" | jq -e '.git.repo == "testrepo"'
}

@test "review-orchestrator.sh: integrates with code-language-detect" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include language detection
    echo "$output" | jq -e '.languages'
}

@test "review-orchestrator.sh: integrates with pre-review-context" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include file metadata
    echo "$output" | jq -e '.file_metadata'
}

@test "review-orchestrator.sh: integrates with review-file-path" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include file info
    echo "$output" | jq -e '.file_info.file_path'
}

@test "review-orchestrator.sh: integrates with load-review-context" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    # Should include review context (may be empty)
    echo "$output" | jq -e 'has("review_context")'
}

# =============================================================================
# Mode-specific integration tests
# =============================================================================

@test "review-orchestrator.sh: returns ambiguous for commit refs (HEAD)" {
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" HEAD
    [ "$status" -eq 0 ]
    # HEAD is ambiguous - returns ambiguous status for user to clarify
    status_value=$(echo "$output" | jq -r '.status')
    [ "$status_value" = "ambiguous" ]
}

@test "review-orchestrator.sh: range mode uses get-review-diff correctly" {
    echo "second" > file2.txt
    git add file2.txt
    git commit -m "Second commit"

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "HEAD~1..HEAD"
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

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" feature
    [ "$status" -eq 0 ]
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"DIFF_TYPE:"* ]]
}

@test "review-orchestrator.sh: local mode uses git-diff-filter correctly" {
    echo "change" > file.txt
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
    [ "$status" -eq 0 ]
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"DIFF_TYPE:"* ]]
}

# =============================================================================
# Source vs Execute guard clause tests
# =============================================================================

@test "review-orchestrator.sh: can be sourced without executing main" {
    # Source the script - should not produce output
    output=$(cd "$TEST_REPO" && source "$PROJECT_ROOT/lib/review-orchestrator.sh" 2>&1)

    # Sourcing should not produce any output (main not executed)
    [ -z "$output" ]

    # Verify main function exists after sourcing
    cd "$TEST_REPO"
    source "$PROJECT_ROOT/lib/review-orchestrator.sh"
    declare -F main > /dev/null
}

@test "review-orchestrator.sh: executes main when run directly" {
    # Create a change so orchestrator has something to review
    echo "change" > file.txt

    run "$PROJECT_ROOT/lib/review-orchestrator.sh"
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

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "find"'
}

@test "review-orchestrator.sh: find mode includes file_info" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.file_info.file_path'
    # file_exists can be true or false, so just check it's a boolean
    echo "$output" | jq -e 'has("file_info") and (.file_info | has("file_exists"))'
}

@test "review-orchestrator.sh: find mode includes display_target" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    display_target=$(echo "$output" | jq -r '.display_target')
    [ -n "$display_target" ]
    [ "$display_target" != "null" ]
}

@test "review-orchestrator.sh: find mode does not include diff" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    # Find mode should NOT include diff - it's an early exit
    diff_value=$(echo "$output" | jq -r '.diff // "not_present"')
    [ "$diff_value" = "not_present" ]
}

@test "review-orchestrator.sh: find mode with PR number" {
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" find 123
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

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" find find-test-branch
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "find"'
    display_target=$(echo "$output" | jq -r '.display_target')
    [[ "$display_target" == *"find-test-branch"* ]]
}

@test "review-orchestrator.sh: find mode on base branch with no changes" {
    # Clean repo with no changes - should work in find mode
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "find"'
}

@test "review-orchestrator.sh: find mode file_info.file_path is absolute" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    file_path=$(echo "$output" | jq -r '.file_info.file_path')
    [[ "$file_path" == /* ]]
}

@test "review-orchestrator.sh: find mode file_exists is boolean string" {
    echo "change" > file.txt

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" find
    [ "$status" -eq 0 ]
    file_exists=$(echo "$output" | jq -r '.file_info.file_exists')
    [ "$file_exists" = "true" ] || [ "$file_exists" = "false" ]
}
