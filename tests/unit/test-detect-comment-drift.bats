#!/usr/bin/env bats
# Tests for detect-comment-drift.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/detect-comment-drift.sh"
    FIXTURES_DIR="$PROJECT_ROOT/tests/fixtures/diffs"

    # Create temp directory for mock scripts
    MOCK_DIR=$(mktemp -d)
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$MOCK_DIR"
}

# Helper to create a mock gh command
create_mock_gh() {
    local head_sha="$1"
    local diff_file="${2:-}"
    cat > "$MOCK_DIR/gh" << GHEOF
#!/bin/bash
if [[ "\$*" == *"--jq"*".head.sha"* ]]; then
    echo '${head_sha}'
elif [[ "\$*" == *"pr diff"* ]]; then
    cat '${diff_file}'
else
    echo '[]'
fi
GHEOF
    chmod +x "$MOCK_DIR/gh"
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "detect-comment-drift: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "detect-comment-drift: uses set -euo pipefail" {
    run bash -c "head -40 '$SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "detect-comment-drift: has required functions" {
    run bash -c "source '$SCRIPT' && declare -f get_current_pr_head > /dev/null"
    [ "$status" -eq 0 ]

    run bash -c "source '$SCRIPT' && declare -f fetch_current_diff > /dev/null"
    [ "$status" -eq 0 ]

    run bash -c "source '$SCRIPT' && declare -f extract_line_content_from_diff > /dev/null"
    [ "$status" -eq 0 ]

    run bash -c "source '$SCRIPT' && declare -f find_line_in_diff > /dev/null"
    [ "$status" -eq 0 ]

    run bash -c "source '$SCRIPT' && declare -f remap_comment > /dev/null"
    [ "$status" -eq 0 ]

    run bash -c "source '$SCRIPT' && declare -f main > /dev/null"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Input validation tests
# =============================================================================

@test "detect-comment-drift: rejects invalid JSON input" {
    run bash -c "echo 'not json' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid JSON"* ]]
}

# =============================================================================
# No drift tests (same commit)
# =============================================================================

@test "detect-comment-drift: no drift when same commit SHA" {
    create_mock_gh "abc123" ""

    local input='{"owner": "org", "repo": "repo", "pr_number": 42, "review_commit": "abc123", "comments": [{"path": "src/auth.ts", "line": 10, "body": "Consider..."}]}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == false'
    echo "$output" | jq -e '.comments | length == 1'
    echo "$output" | jq -e '.unmapped_comments | length == 0'
}

@test "detect-comment-drift: returns original comments unchanged when no drift" {
    create_mock_gh "abc123" ""

    local input='{"owner": "org", "repo": "repo", "pr_number": 42, "review_commit": "abc123", "comments": [{"path": "src/auth.ts", "line": 10, "side": "RIGHT", "body": "Consider..."}]}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]

    local path line body
    path=$(echo "$output" | jq -r '.comments[0].path')
    line=$(echo "$output" | jq -r '.comments[0].line')
    body=$(echo "$output" | jq -r '.comments[0].body')
    [ "$path" = "src/auth.ts" ]
    [ "$line" = "10" ]
    [ "$body" = "Consider..." ]
}

# =============================================================================
# Missing review_commit tests
# =============================================================================

@test "detect-comment-drift: skips drift detection when review_commit is missing" {
    local input='{"owner": "org", "repo": "repo", "pr_number": 42, "comments": [{"path": "src/auth.ts", "line": 10, "body": "Consider..."}]}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == false'
    echo "$output" | jq -e '.drift_summary == "skipped (no review commit)"'
}

@test "detect-comment-drift: skips drift detection when review_commit is null" {
    local input='{"owner": "org", "repo": "repo", "pr_number": 42, "review_commit": null, "comments": [{"path": "src/auth.ts", "line": 10, "body": "Consider..."}]}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == false'
}

# =============================================================================
# Drift detection with successful remap
# =============================================================================

@test "detect-comment-drift: detects drift and remaps comment to new position" {
    # The original diff has the token validation line at new-file line 10.
    # The updated diff has it at new-file line 18 (extra lines added above).
    create_mock_gh "def456" "$FIXTURES_DIR/drift-updated.diff"

    local original_diff
    original_diff=$(cat "$FIXTURES_DIR/drift-original.diff")
    local tmpinput
    tmpinput=$(mktemp)

    # Use --arg for the line_content to preserve single quotes correctly
    local line_content
    line_content="    return token.length > 10 && token.startsWith('sk_');"

    jq -n \
        --arg diff "$original_diff" \
        --arg lc "$line_content" \
        '{
            owner: "org",
            repo: "repo",
            pr_number: 42,
            review_commit: "abc123",
            original_diff: $diff,
            comments: [{
                path: "src/auth.ts",
                line: 10,
                side: "RIGHT",
                body: "Consider adding token format validation",
                line_content: $lc
            }]
        }' > "$tmpinput"

    run bash -c "cat '$tmpinput' | '$SCRIPT' 2>/dev/null"
    rm -f "$tmpinput"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == true'
    echo "$output" | jq -e '.review_commit == "abc123"'
    echo "$output" | jq -e '.current_commit == "def456"'
    # The comment should be remapped (line moved from 10 to 18)
    echo "$output" | jq -e '.comments | length == 1'
    echo "$output" | jq -e '.unmapped_comments | length == 0'
}

@test "detect-comment-drift: uses line_content for matching when provided" {
    create_mock_gh "def456" "$FIXTURES_DIR/drift-updated.diff"

    local input
    input=$(jq -n '{
        owner: "org",
        repo: "repo",
        pr_number: 42,
        review_commit: "abc123",
        comments: [{
            path: "src/utils.ts",
            line: 6,
            side: "RIGHT",
            body: "Magic number",
            line_content: "export const MAX_RETRIES = 3;"
        }]
    }')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == true'
    echo "$output" | jq -e '.comments | length == 1'
}

# =============================================================================
# Drift with unmapped comments
# =============================================================================

@test "detect-comment-drift: moves comment to unmapped when line content removed" {
    create_mock_gh "def456" "$FIXTURES_DIR/drift-updated.diff"

    local input
    input=$(jq -n '{
        owner: "org",
        repo: "repo",
        pr_number: 42,
        review_commit: "abc123",
        comments: [{
            path: "src/auth.ts",
            line: 5,
            side: "RIGHT",
            body: "This line has a problem",
            line_content: "this_content_does_not_exist_anywhere();"
        }]
    }')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == true'
    echo "$output" | jq -e '.comments | length == 0'
    echo "$output" | jq -e '.unmapped_comments | length == 1'
    echo "$output" | jq -e '.unmapped_comments[0].reason != null'
}

@test "detect-comment-drift: moves comment to unmapped when file removed from diff" {
    # Create a mock that returns a diff without the target file
    local simple_diff="$FIXTURES_DIR/simple-single-file.diff"
    create_mock_gh "def456" "$simple_diff"

    local input
    input=$(jq -n '{
        owner: "org",
        repo: "repo",
        pr_number: 42,
        review_commit: "abc123",
        comments: [{
            path: "src/auth.ts",
            line: 5,
            side: "RIGHT",
            body: "This file is gone",
            line_content: "some_code();"
        }]
    }')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == true'
    echo "$output" | jq -e '.comments | length == 0'
    echo "$output" | jq -e '.unmapped_comments | length == 1'
    echo "$output" | jq -e '.unmapped_comments[0].reason == "file removed from diff"'
}

# =============================================================================
# Content matching edge cases
# =============================================================================

@test "detect-comment-drift: handles trimmed whitespace matching" {
    create_mock_gh "def456" "$FIXTURES_DIR/drift-updated.diff"

    # The line_content has extra whitespace that should be trimmed during matching
    local input
    input=$(jq -n '{
        owner: "org",
        repo: "repo",
        pr_number: 42,
        review_commit: "abc123",
        comments: [{
            path: "src/auth.ts",
            line: 3,
            side: "RIGHT",
            body: "Interface naming",
            line_content: "  export interface AuthConfig {  "
        }]
    }')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == true'
    echo "$output" | jq -e '.comments | length == 1'
}

@test "detect-comment-drift: handles empty comments array" {
    create_mock_gh "def456" "$FIXTURES_DIR/drift-updated.diff"

    local input='{"owner": "org", "repo": "repo", "pr_number": 42, "review_commit": "abc123", "comments": []}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == true'
    echo "$output" | jq -e '.comments | length == 0'
    echo "$output" | jq -e '.unmapped_comments | length == 0'
}

# =============================================================================
# extract_line_content_from_diff tests
# =============================================================================

@test "detect-comment-drift: extracts line content from original diff" {
    local diff
    diff=$(cat "$FIXTURES_DIR/drift-original.diff")

    # Line 10 in src/auth.ts in the original diff is the token validation line
    run bash -c "
        source '$SCRIPT'
        extract_line_content_from_diff \"\$(cat '$FIXTURES_DIR/drift-original.diff')\" 'src/auth.ts' 10
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"token.length > 10"* ]]
}

@test "detect-comment-drift: returns empty for nonexistent file" {
    run bash -c "
        source '$SCRIPT'
        extract_line_content_from_diff \"\$(cat '$FIXTURES_DIR/drift-original.diff')\" 'nonexistent.ts' 1
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "detect-comment-drift: returns empty for line outside diff range" {
    run bash -c "
        source '$SCRIPT'
        extract_line_content_from_diff \"\$(cat '$FIXTURES_DIR/drift-original.diff')\" 'src/auth.ts' 999
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# find_line_in_diff tests
# =============================================================================

@test "detect-comment-drift: finds line at new position in diff" {
    local diff
    diff=$(cat "$FIXTURES_DIR/drift-updated.diff")

    run bash -c "
        source '$SCRIPT'
        find_line_in_diff \"\$(cat '$FIXTURES_DIR/drift-updated.diff')\" 'src/utils.ts' 'export const MAX_RETRIES = 3;' 6
    "
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "detect-comment-drift: returns empty when content not found" {
    run bash -c "
        source '$SCRIPT'
        find_line_in_diff \"\$(cat '$FIXTURES_DIR/drift-updated.diff')\" 'src/auth.ts' 'this_line_does_not_exist();' 1
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# file_in_diff tests
# =============================================================================

@test "detect-comment-drift: detects file present in diff" {
    run bash -c "
        source '$SCRIPT'
        file_in_diff \"\$(cat '$FIXTURES_DIR/drift-original.diff')\" 'src/auth.ts'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "detect-comment-drift: detects file absent from diff" {
    run bash -c "
        source '$SCRIPT'
        file_in_diff \"\$(cat '$FIXTURES_DIR/drift-original.diff')\" 'nonexistent.ts'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

# =============================================================================
# Drift summary tests
# =============================================================================

@test "detect-comment-drift: produces correct drift summary" {
    create_mock_gh "def456" "$FIXTURES_DIR/drift-updated.diff"

    local input
    input=$(jq -n '{
        owner: "org",
        repo: "repo",
        pr_number: 42,
        review_commit: "abc123",
        comments: [
            {
                path: "src/utils.ts",
                line: 6,
                side: "RIGHT",
                body: "Magic number",
                line_content: "export const MAX_RETRIES = 3;"
            },
            {
                path: "src/auth.ts",
                line: 5,
                side: "RIGHT",
                body: "This is gone",
                line_content: "this_content_does_not_exist_anywhere();"
            }
        ]
    }')

    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == true'
    echo "$output" | jq -e '.drift_summary | contains("unmapped")'
}

# =============================================================================
# Output format tests
# =============================================================================

@test "detect-comment-drift: outputs valid JSON" {
    create_mock_gh "abc123" ""

    local input='{"owner": "org", "repo": "repo", "pr_number": 42, "review_commit": "abc123", "comments": []}'
    run bash -c "echo '$input' | '$SCRIPT' | jq empty"
    [ "$status" -eq 0 ]
}

@test "detect-comment-drift: includes all required output fields" {
    create_mock_gh "abc123" ""

    local input='{"owner": "org", "repo": "repo", "pr_number": 42, "review_commit": "abc123", "comments": []}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'has("drift_detected")'
    echo "$output" | jq -e 'has("review_commit")'
    echo "$output" | jq -e 'has("current_commit")'
    echo "$output" | jq -e 'has("comments")'
    echo "$output" | jq -e 'has("unmapped_comments")'
    echo "$output" | jq -e 'has("drift_summary")'
}

# =============================================================================
# Graceful failure tests
# =============================================================================

@test "detect-comment-drift: handles gh API failure gracefully" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
echo "API rate limit exceeded" >&2
exit 1
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "repo", "pr_number": 42, "review_commit": "abc123", "comments": [{"path": "test.ts", "line": 1, "body": "hi"}]}'
    # Redirect stderr to /dev/null so warning messages don't pollute the JSON output
    run bash -c "echo '$input' | '$SCRIPT' 2>/dev/null"
    [ "$status" -eq 0 ]
    # Should return gracefully with original comments
    echo "$output" | jq -e '.drift_detected == false'
    echo "$output" | jq -e '.comments | length == 1'
}

# =============================================================================
# Integration with original_diff tests
# =============================================================================

@test "detect-comment-drift: extracts line_content from original_diff when not on comment" {
    create_mock_gh "def456" "$FIXTURES_DIR/drift-updated.diff"

    local original_diff
    original_diff=$(cat "$FIXTURES_DIR/drift-original.diff")

    # Comment targets line 5 (MAX_RETRIES) without line_content, but original_diff is provided
    # so the script should extract it automatically and use it for matching
    local tmpinput
    tmpinput=$(mktemp)

    jq -n \
        --arg diff "$original_diff" \
        '{
            owner: "org",
            repo: "repo",
            pr_number: 42,
            review_commit: "abc123",
            original_diff: $diff,
            comments: [{
                path: "src/utils.ts",
                line: 5,
                side: "RIGHT",
                body: "Magic number"
            }]
        }' > "$tmpinput"

    run bash -c "cat '$tmpinput' | '$SCRIPT' 2>/dev/null"
    rm -f "$tmpinput"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift_detected == true'
    echo "$output" | jq -e '.comments | length == 1'
}
