#!/usr/bin/env bats
# Tests for learn-from-pr.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create temporary directories for testing
    TEST_DIR=$(mktemp -d)
    export TEST_DIR

    # Create mock review root directory
    MOCK_REVIEW_ROOT="$TEST_DIR/reviews"
    mkdir -p "$MOCK_REVIEW_ROOT"
    export MOCK_REVIEW_ROOT

    # Create a mock git repository
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init -q
    git config commit.gpgsign false
    git config user.email "test@example.com"
    git config user.name "Test User"
    git remote add origin "https://github.com/testorg/testrepo.git"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"
    export TEST_REPO
}

teardown() {
    rm -rf "$TEST_DIR"
    rm -rf "$TEST_REPO"
}

# =============================================================================
# Basic functionality tests
# =============================================================================

@test "learn-from-pr.sh: exists and is executable" {
    [ -x "$PROJECT_ROOT/skills/review-code/scripts/learn-from-pr.sh" ]
}

@test "learn-from-pr.sh: can be sourced without executing main" {
    run bash -c "source '$PROJECT_ROOT/skills/review-code/scripts/learn-from-pr.sh' && echo 'sourced ok'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced ok"* ]]
}

@test "learn-from-pr.sh: requires PR identifier argument" {
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-from-pr.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# Argument parsing tests
# =============================================================================

@test "learn-from-pr.sh: rejects unknown arguments" {
    cd "$TEST_REPO"
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-from-pr.sh" 123 --unknown
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown argument"* ]]
}

@test "learn-from-pr.sh: accepts --org flag" {
    cd "$TEST_REPO"
    # Will fail later due to missing review file, but parsing should succeed
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-from-pr.sh" 123 --org myorg --repo myrepo
    [[ "$output" != *"Unknown argument"* ]]
}

@test "learn-from-pr.sh: accepts --repo flag" {
    cd "$TEST_REPO"
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-from-pr.sh" 123 --org myorg --repo myrepo
    [[ "$output" != *"Unknown argument"* ]]
}

@test "learn-from-pr.sh: rejects invalid PR identifier" {
    cd "$TEST_REPO"
    run "$PROJECT_ROOT/skills/review-code/scripts/learn-from-pr.sh" "not-a-pr"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid PR identifier"* ]]
}

# =============================================================================
# PR identifier parsing tests
# =============================================================================

@test "learn-from-pr.sh: extracts PR number from numeric input" {
    # Test the regex pattern used in the script
    local pr_identifier="123"
    if [[ "${pr_identifier}" =~ ^[0-9]+$ ]]; then
        [ "$pr_identifier" = "123" ]
    else
        fail "Should match numeric PR"
    fi
}

@test "learn-from-pr.sh: extracts org/repo/PR from GitHub URL" {
    local pr_identifier="https://github.com/haacked/review-code/pull/42"
    if [[ "${pr_identifier}" =~ ^https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        [ "${BASH_REMATCH[1]}" = "haacked" ]
        [ "${BASH_REMATCH[2]}" = "review-code" ]
        [ "${BASH_REMATCH[3]}" = "42" ]
    else
        fail "Should match GitHub URL pattern"
    fi
}

@test "learn-from-pr.sh: handles URL with trailing segments" {
    local pr_identifier="https://github.com/org/repo/pull/123/files"
    if [[ "${pr_identifier}" =~ ^https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        [ "${BASH_REMATCH[3]}" = "123" ]
    else
        fail "Should match URL with trailing path"
    fi
}

@test "learn-from-pr.sh: rejects non-GitHub URLs" {
    local pr_identifier="https://gitlab.com/org/repo/merge_requests/1"
    if [[ "${pr_identifier}" =~ ^https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        fail "Should not match GitLab URL"
    fi
}

# =============================================================================
# Review file detection tests
# =============================================================================

@test "learn-from-pr.sh: errors when review file not found" {
    cd "$TEST_REPO"

    # Create config pointing to our mock review root
    mkdir -p "$TEST_DIR/.claude/skills/review-code"
    echo "REVIEW_ROOT_PATH=$MOCK_REVIEW_ROOT" > "$TEST_DIR/.claude/skills/review-code/.env"

    HOME="$TEST_DIR" run "$PROJECT_ROOT/skills/review-code/scripts/learn-from-pr.sh" 123 --org testorg --repo testrepo
    [ "$status" -eq 1 ]
    [[ "$output" == *"No review file found"* ]]
}

@test "learn-from-pr.sh: suggests running review-code when no review exists" {
    cd "$TEST_REPO"

    mkdir -p "$TEST_DIR/.claude/skills/review-code"
    echo "REVIEW_ROOT_PATH=$MOCK_REVIEW_ROOT" > "$TEST_DIR/.claude/skills/review-code/.env"

    HOME="$TEST_DIR" run "$PROJECT_ROOT/skills/review-code/scripts/learn-from-pr.sh" 456 --org testorg --repo testrepo
    [ "$status" -eq 1 ]
    [[ "$output" == *"/review-code"* ]]
}

# =============================================================================
# Cross-reference logic tests (unit testing the patterns)
# =============================================================================

@test "learn-from-pr.sh: jq matches file in files_changed_after_review" {
    local files_changed='["src/auth.py", "src/login.py", "tests/test_auth.py"]'
    local finding_file="src/auth.py"

    if echo "$files_changed" | jq -e --arg f "$finding_file" 'index($f) != null' > /dev/null 2>&1; then
        true
    else
        fail "Should find file in changed files"
    fi
}

@test "learn-from-pr.sh: jq correctly reports file not in files_changed_after_review" {
    local files_changed='["src/auth.py", "src/login.py"]'
    local finding_file="other/file.py"

    if echo "$files_changed" | jq -e --arg f "$finding_file" 'index($f) != null' > /dev/null 2>&1; then
        fail "Should not find file in changed files"
    else
        true
    fi
}

@test "learn-from-pr.sh: line proximity check works within 10 lines" {
    local comment_line=100
    local finding_line=95
    local line_diff=$((comment_line - finding_line))

    [ ${line_diff#-} -le 10 ]
}

@test "learn-from-pr.sh: line proximity check fails beyond 10 lines" {
    local comment_line=100
    local finding_line=50
    local line_diff=$((comment_line - finding_line))

    [ ${line_diff#-} -gt 10 ]
}

@test "learn-from-pr.sh: handles negative line difference" {
    local comment_line=50
    local finding_line=100
    local line_diff=$((comment_line - finding_line))

    # ${line_diff#-} removes the negative sign for absolute value
    [ ${line_diff#-} -eq 50 ]
}

# =============================================================================
# Date comparison tests
# =============================================================================

@test "learn-from-pr.sh: epoch comparison works for dates" {
    local review_file_epoch=1704067200  # Jan 1, 2024 00:00:00 UTC
    local commit_epoch=1704153600       # Jan 2, 2024 00:00:00 UTC

    [ "$commit_epoch" -gt "$review_file_epoch" ]
}

@test "learn-from-pr.sh: date conversion works on macOS" {
    if [[ "${OSTYPE}" != "darwin"* ]]; then
        skip "macOS-specific test"
    fi

    local commit_date="2024-01-15T10:30:00Z"
    local commit_epoch
    commit_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$commit_date" +%s 2>/dev/null)

    [ -n "$commit_epoch" ]
    [[ "$commit_epoch" =~ ^[0-9]+$ ]]
}

@test "learn-from-pr.sh: date conversion works on Linux" {
    if [[ "${OSTYPE}" == "darwin"* ]]; then
        skip "Linux-specific test"
    fi

    local commit_date="2024-01-15T10:30:00Z"
    local commit_epoch
    commit_epoch=$(date -d "$commit_date" +%s 2>/dev/null)

    [ -n "$commit_epoch" ]
    [[ "$commit_epoch" =~ ^[0-9]+$ ]]
}

# =============================================================================
# JSON output structure tests
# =============================================================================

@test "learn-from-pr.sh: output structure includes required fields" {
    # Test the jq command that builds the final output
    local output
    output=$(jq -n \
        --arg pr_number "123" \
        --arg org "testorg" \
        --arg repo "testrepo" \
        --arg state "MERGED" \
        --arg merged_at "2024-01-15T10:30:00Z" \
        --arg review_file "/path/to/review.md" \
        --argjson claude_findings "[]" \
        --argjson other_findings "[]" \
        --argjson prompts_needed "[]" \
        --argjson files_changed "[]" \
        '{
            pr_number: ($pr_number | tonumber),
            org: $org,
            repo: $repo,
            state: $state,
            merged_at: $merged_at,
            review_file: $review_file,
            claude_findings: $claude_findings,
            other_findings: $other_findings,
            prompts_needed: $prompts_needed,
            files_changed_after_review: $files_changed,
            summary: {
                claude_total: 0,
                claude_addressed: 0,
                claude_not_addressed: 0,
                other_total: 0,
                other_caught_by_claude: 0,
                other_missed_by_claude: 0
            }
        }')

    echo "$output" | jq -e 'has("pr_number")' > /dev/null
    echo "$output" | jq -e 'has("org")' > /dev/null
    echo "$output" | jq -e 'has("repo")' > /dev/null
    echo "$output" | jq -e 'has("claude_findings")' > /dev/null
    echo "$output" | jq -e 'has("other_findings")' > /dev/null
    echo "$output" | jq -e 'has("prompts_needed")' > /dev/null
    echo "$output" | jq -e 'has("summary")' > /dev/null
}

@test "learn-from-pr.sh: summary calculates addressed findings" {
    local claude_findings='[{"addressed":"likely"},{"addressed":"not_modified"},{"addressed":"likely"}]'

    local addressed_count
    addressed_count=$(echo "$claude_findings" | jq '[.[] | select(.addressed == "likely")] | length')
    [ "$addressed_count" -eq 2 ]

    local not_addressed_count
    not_addressed_count=$(echo "$claude_findings" | jq '[.[] | select(.addressed == "not_modified")] | length')
    [ "$not_addressed_count" -eq 1 ]
}

@test "learn-from-pr.sh: summary calculates claude_caught for other findings" {
    local other_findings='[{"claude_caught":true},{"claude_caught":false},{"claude_caught":true}]'

    local caught_count
    caught_count=$(echo "$other_findings" | jq '[.[] | select(.claude_caught == true)] | length')
    [ "$caught_count" -eq 2 ]

    local missed_count
    missed_count=$(echo "$other_findings" | jq '[.[] | select(.claude_caught == false)] | length')
    [ "$missed_count" -eq 1 ]
}

# =============================================================================
# prompts_needed logic tests
# =============================================================================

@test "learn-from-pr.sh: identifies unaddressed findings for prompts" {
    local finding='{"file":"auth.py","line":45,"addressed":"not_modified"}'
    local prompts_needed="[]"

    prompts_needed=$(echo "$prompts_needed" | jq --argjson finding "$finding" \
        '. + [{type: "unaddressed", finding: $finding}]')

    echo "$prompts_needed" | jq -e 'length == 1' > /dev/null
    echo "$prompts_needed" | jq -e '.[0].type == "unaddressed"' > /dev/null
}

@test "learn-from-pr.sh: identifies missed findings for prompts" {
    local finding='{"file":"auth.py","line":45,"claude_caught":false,"addressed":"likely"}'
    local prompts_needed="[]"

    local claude_caught
    claude_caught=$(echo "$finding" | jq -r '.claude_caught')
    local addressed
    addressed=$(echo "$finding" | jq -r '.addressed')

    if [[ "$claude_caught" == "false" ]] && [[ "$addressed" == "likely" ]]; then
        prompts_needed=$(echo "$prompts_needed" | jq --argjson finding "$finding" \
            '. + [{type: "missed", finding: $finding}]')
    fi

    echo "$prompts_needed" | jq -e 'length == 1' > /dev/null
    echo "$prompts_needed" | jq -e '.[0].type == "missed"' > /dev/null
}
