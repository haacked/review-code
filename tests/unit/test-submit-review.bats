#!/usr/bin/env bats
# Tests for submit-review.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/submit-review.sh"

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

@test "submit-review: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "submit-review: uses set -euo pipefail" {
    run bash -c "head -40 '$SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "submit-review: has require_field function" {
    run bash -c "grep -q '^require_field()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "submit-review: has validate_event function" {
    run bash -c "grep -q '^validate_event()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "submit-review: has verify_pending_state function" {
    run bash -c "grep -q '^verify_pending_state()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "submit-review: has submit_review function" {
    run bash -c "grep -q '^submit_review()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "submit-review: has main function" {
    run bash -c "grep -q '^main()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Input validation tests
# =============================================================================

@test "submit-review: rejects invalid JSON input" {
    run bash -c "echo 'not json' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid JSON"* ]]
}

@test "submit-review: rejects missing owner" {
    local input='{"repo": "test", "pr_number": 1, "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing owner"* ]]
}

@test "submit-review: rejects missing repo" {
    local input='{"owner": "org", "pr_number": 1, "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing repo"* ]]
}

@test "submit-review: rejects missing pr_number" {
    local input='{"owner": "org", "repo": "test", "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing pr_number"* ]]
}

@test "submit-review: rejects missing review_id" {
    local input='{"owner": "org", "repo": "test", "pr_number": 1, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing review_id"* ]]
}

@test "submit-review: rejects missing event" {
    local input='{"owner": "org", "repo": "test", "pr_number": 1, "review_id": 123}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing event"* ]]
}

# =============================================================================
# Event validation tests
# =============================================================================

@test "submit-review: validate_event accepts APPROVE" {
    run bash -c "source '$SCRIPT' && validate_event 'APPROVE'"
    [ "$status" -eq 0 ]
}

@test "submit-review: validate_event accepts REQUEST_CHANGES" {
    run bash -c "source '$SCRIPT' && validate_event 'REQUEST_CHANGES'"
    [ "$status" -eq 0 ]
}

@test "submit-review: validate_event accepts COMMENT" {
    run bash -c "source '$SCRIPT' && validate_event 'COMMENT'"
    [ "$status" -eq 0 ]
}

@test "submit-review: validate_event rejects invalid event" {
    run bash -c "source '$SCRIPT' && validate_event 'DISMISS'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid event"* ]]
    [[ "$output" == *"DISMISS"* ]]
}

@test "submit-review: validate_event rejects lowercase event" {
    run bash -c "source '$SCRIPT' && validate_event 'comment'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid event"* ]]
}

@test "submit-review: rejects invalid event in full flow" {
    local input='{"owner": "org", "repo": "test", "pr_number": 1, "review_id": 123, "event": "INVALID"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid event"* ]]
}

# =============================================================================
# PENDING state guard tests
# =============================================================================

@test "submit-review: rejects already-submitted review (APPROVED state)" {
    create_mock_gh '{"id": 123, "state": "APPROVED"}'

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"APPROVED"* ]]
    [[ "$output" == *"not PENDING"* ]]
}

@test "submit-review: rejects already-submitted review (COMMENTED state)" {
    create_mock_gh '{"id": 123, "state": "COMMENTED"}'

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"COMMENTED"* ]]
    [[ "$output" == *"not PENDING"* ]]
}

@test "submit-review: rejects already-submitted review (CHANGES_REQUESTED state)" {
    create_mock_gh '{"id": 123, "state": "CHANGES_REQUESTED"}'

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHANGES_REQUESTED"* ]]
    [[ "$output" == *"not PENDING"* ]]
}

@test "submit-review: handles review fetch failure" {
    create_failing_mock_gh "Not Found"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "review_id": 99999, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to fetch review"* ]]
}

# =============================================================================
# Main flow tests with mocks
# =============================================================================

@test "submit-review: submits COMMENT successfully" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/events"* ]]; then
    echo '{"id": 123, "state": "COMMENTED"}'
else
    echo '{"id": 123, "state": "PENDING"}'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 42, "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"success": true'* ]]
    [[ "$output" == *'"event": "COMMENT"'* ]]
    [[ "$output" == *'"state": "COMMENTED"'* ]]
}

@test "submit-review: submits APPROVE successfully" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/events"* ]]; then
    echo '{"id": 123, "state": "APPROVED"}'
else
    echo '{"id": 123, "state": "PENDING"}'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 42, "review_id": 123, "event": "APPROVE"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"success": true'* ]]
    [[ "$output" == *'"event": "APPROVE"'* ]]
    [[ "$output" == *'"state": "APPROVED"'* ]]
}

@test "submit-review: submits REQUEST_CHANGES successfully" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/events"* ]]; then
    echo '{"id": 123, "state": "CHANGES_REQUESTED"}'
else
    echo '{"id": 123, "state": "PENDING"}'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 42, "review_id": 123, "event": "REQUEST_CHANGES"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"success": true'* ]]
    [[ "$output" == *'"event": "REQUEST_CHANGES"'* ]]
    [[ "$output" == *'"state": "CHANGES_REQUESTED"'* ]]
}

@test "submit-review: handles API failure on submit" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/events"* ]]; then
    echo "Unprocessable Entity" >&2
    exit 1
else
    echo '{"id": 123, "state": "PENDING"}'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 42, "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *'"success": false'* ]]
}

# =============================================================================
# Output format tests
# =============================================================================

@test "submit-review: outputs valid JSON on success" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/events"* ]]; then
    echo '{"id": 123, "state": "COMMENTED"}'
else
    echo '{"id": 123, "state": "PENDING"}'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 42, "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT' | jq empty"
    [ "$status" -eq 0 ]
}

@test "submit-review: includes review_url in output" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/events"* ]]; then
    echo '{"id": 123, "state": "COMMENTED"}'
else
    echo '{"id": 123, "state": "PENDING"}'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 42, "review_id": 123, "event": "COMMENT"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"review_url": "https://github.com/org/test/pull/42#pullrequestreview-123"'* ]]
}

@test "submit-review: includes review_id in output" {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/bin/bash
if [[ "$*" == *"/events"* ]]; then
    echo '{"id": 456, "state": "APPROVED"}'
else
    echo '{"id": 456, "state": "PENDING"}'
fi
EOF
    chmod +x "$MOCK_DIR/gh"

    local input='{"owner": "org", "repo": "test", "pr_number": 1, "review_id": 456, "event": "APPROVE"}'
    run bash -c "echo '$input' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"review_id": 456'* ]]
}

# =============================================================================
# require_field tests
# =============================================================================

@test "submit-review: require_field accepts valid value" {
    run bash -c "source '$SCRIPT' && require_field 'test_value' 'field_name'"
    [ "$status" -eq 0 ]
}

@test "submit-review: require_field rejects empty value" {
    run bash -c "source '$SCRIPT' && require_field '' 'field_name'"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"success": false'* ]]
    [[ "$output" == *'"error": "Missing field_name"'* ]]
}

@test "submit-review: require_field rejects null value" {
    run bash -c "source '$SCRIPT' && require_field 'null' 'field_name'"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"success": false'* ]]
    [[ "$output" == *'"error": "Missing field_name"'* ]]
}
