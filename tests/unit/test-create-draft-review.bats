#!/usr/bin/env bats
# Tests for create-draft-review.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/create-draft-review.sh"
    FIXTURES_DIR="$PROJECT_ROOT/tests/fixtures/reviews"

    # Create temp directory for mock scripts
    MOCK_DIR=$(mktemp -d)
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$MOCK_DIR"
}

# Helper to create a mock gh command
create_mock_gh() {
    local response="$1"
    cat > "$MOCK_DIR/gh" << EOF
#!/bin/bash
echo '$response'
EOF
    chmod +x "$MOCK_DIR/gh"
}

# Helper to create a mock gh that fails
create_failing_mock_gh() {
    local error_msg="$1"
    cat > "$MOCK_DIR/gh" << EOF
#!/bin/bash
echo '$error_msg' >&2
exit 1
EOF
    chmod +x "$MOCK_DIR/gh"
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "create-draft-review: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "create-draft-review: uses set -euo pipefail" {
    run bash -c "head -40 '$SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "create-draft-review: has require_field function" {
    run bash -c "grep -q '^require_field()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "create-draft-review: has get_existing_pending_review function" {
    run bash -c "grep -q '^get_existing_pending_review()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "create-draft-review: has delete_pending_review function" {
    run bash -c "grep -q '^delete_pending_review()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "create-draft-review: has create_pending_review function" {
    run bash -c "grep -q '^create_pending_review()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "create-draft-review: has main function" {
    run bash -c "grep -q '^main()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# require_field tests
# =============================================================================

@test "create-draft-review: require_field accepts valid value" {
    run bash -c "source '$SCRIPT' && require_field 'test_value' 'field_name'"
    [ "$status" -eq 0 ]
}

@test "create-draft-review: require_field rejects empty value" {
    run bash -c "source '$SCRIPT' && require_field '' 'field_name'"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"success": false'* ]]
    [[ "$output" == *'"error": "Missing field_name"'* ]]
}

@test "create-draft-review: require_field rejects null value" {
    run bash -c "source '$SCRIPT' && require_field 'null' 'field_name'"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"success": false'* ]]
    [[ "$output" == *'"error": "Missing field_name"'* ]]
}

# =============================================================================
# Input validation tests
# =============================================================================

@test "create-draft-review: rejects invalid JSON input" {
    run bash -c "echo 'not json' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid JSON"* ]]
}

@test "create-draft-review: rejects missing owner" {
    local input='{"repo": "test", "pr_number": 1, "reviewer_username": "user"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing owner"* ]]
}

@test "create-draft-review: rejects missing repo" {
    local input='{"owner": "org", "pr_number": 1, "reviewer_username": "user"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing repo"* ]]
}

@test "create-draft-review: rejects missing pr_number" {
    local input='{"owner": "org", "repo": "test", "reviewer_username": "user"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing pr_number"* ]]
}

@test "create-draft-review: rejects missing reviewer_username" {
    local input='{"owner": "org", "repo": "test", "pr_number": 1}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing reviewer_username"* ]]
}

# =============================================================================
# get_existing_pending_review tests
# =============================================================================

@test "create-draft-review: get_existing_pending_review returns null when no pending review" {
    create_mock_gh '[]'

    run bash -c "source '$SCRIPT' && get_existing_pending_review 'owner' 'repo' '42' 'testuser'"
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

@test "create-draft-review: get_existing_pending_review finds pending review" {
    local reviews
    reviews=$(cat "$FIXTURES_DIR/pending-review.json")
    # Wrap in array for the reviews endpoint response
    create_mock_gh "[$reviews]"

    run bash -c "source '$SCRIPT' && get_existing_pending_review 'test-owner' 'test-repo' '42' 'testuser'"
    [ "$status" -eq 0 ]
    # Should return review info with review_id
    [[ "$output" == *'"review_id":'* ]]
}

# =============================================================================
# Main flow tests with mocks
# =============================================================================

@test "create-draft-review: creates review successfully" {
    # Mock gh to return empty reviews and then success on create
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/reviews --paginate"* ]]; then
    echo '[]'
elif [[ "$*" == *"--method POST"* ]]; then
    echo '{"id": 99999, "body": "test"}'
else
    echo '[]'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "reviewer_username": "user", "summary": "Test review", "comments": []}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"success": true'* ]]
    [[ "$output" == *'"review_id": 99999'* ]]
}

@test "create-draft-review: creates review with inline comments" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/reviews --paginate"* ]]; then
    echo '[]'
elif [[ "$*" == *"--method POST"* ]]; then
    echo '{"id": 88888, "body": "test"}'
else
    echo '[]'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "reviewer_username": "user", "summary": "Test", "comments": [{"path": "test.ts", "position": 5, "body": "Fix this"}]}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"success": true'* ]]
    [[ "$output" == *'"inline_count": 1'* ]]
}

@test "create-draft-review: replaces existing pending review" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/reviews --paginate"* ]]; then
    echo '[{"id": 11111, "state": "PENDING", "user": {"login": "user"}, "body": "old"}]'
elif [[ "$*" == *"/reviews/11111/comments"* ]]; then
    echo '[]'
elif [[ "$*" == *"--method DELETE"* ]]; then
    echo '{}'
elif [[ "$*" == *"--method POST"* ]]; then
    echo '{"id": 22222, "body": "new"}'
else
    echo '[]'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "reviewer_username": "user", "summary": "New review", "comments": []}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"success": true'* ]]
    [[ "$output" == *'"replaced_existing": true'* ]]
}

@test "create-draft-review: includes unmapped comments in body" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/reviews --paginate"* ]]; then
    echo '[]'
elif [[ "$*" == *"--method POST"* ]]; then
    echo '{"id": 77777, "body": "test"}'
else
    echo '[]'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "reviewer_username": "user", "summary": "Test", "comments": [], "unmapped_comments": [{"description": "General note"}]}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"summary_count": 1'* ]]
}

@test "create-draft-review: handles API failure gracefully" {
    create_failing_mock_gh "API rate limit exceeded"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "reviewer_username": "user", "summary": "Test", "comments": []}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *'"success": false'* ]]
}

# =============================================================================
# Output format tests
# =============================================================================

@test "create-draft-review: outputs valid JSON on success" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/reviews --paginate"* ]]; then
    echo '[]'
elif [[ "$*" == *"--method POST"* ]]; then
    echo '{"id": 66666, "body": "test"}'
else
    echo '[]'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "reviewer_username": "user", "summary": "Test", "comments": []}'
    run bash -c "echo '$input' | '$SCRIPT' | jq empty"
    [ "$status" -eq 0 ]
}

@test "create-draft-review: includes review_url in output" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/reviews --paginate"* ]]; then
    echo '[]'
elif [[ "$*" == *"--method POST"* ]]; then
    echo '{"id": 55555, "body": "test"}'
else
    echo '[]'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 42, "reviewer_username": "user", "summary": "Test", "comments": []}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"review_url": "https://github.com/org/test/pull/42#pullrequestreview-55555"'* ]]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "create-draft-review: handles empty summary" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/reviews --paginate"* ]]; then
    echo '[]'
elif [[ "$*" == *"--method POST"* ]]; then
    echo '{"id": 44444, "body": ""}'
else
    echo '[]'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "reviewer_username": "user", "comments": []}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"success": true'* ]]
}

@test "create-draft-review: handles null comments array" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/reviews --paginate"* ]]; then
    echo '[]'
elif [[ "$*" == *"--method POST"* ]]; then
    echo '{"id": 33333, "body": "test"}'
else
    echo '[]'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "reviewer_username": "user", "summary": "Test"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"inline_count": 0'* ]]
}
