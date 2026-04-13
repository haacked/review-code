#!/usr/bin/env bats
# Tests for copilot-meta-review.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/copilot-meta-review.sh"

    # Create temp directory for mock scripts and test data
    MOCK_DIR=$(mktemp -d)
    TMP_DIR=$(mktemp -d)
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$MOCK_DIR" "$TMP_DIR"
}

# Helper to create a mock copilot that returns structured JSON
create_mock_copilot() {
    local response="$1"
    cat > "$MOCK_DIR/copilot" << MOCKEOF
#!/bin/bash
echo '{"type":"result","content":$response}'
MOCKEOF
    chmod +x "$MOCK_DIR/copilot"
}

# Helper to create a mock copilot that times out (exit 124)
create_timeout_mock_copilot() {
    cat > "$MOCK_DIR/copilot" << 'EOF'
#!/bin/bash
exit 124
EOF
    chmod +x "$MOCK_DIR/copilot"
}

# Helper to create a mock copilot that errors (exit 2)
create_error_mock_copilot() {
    cat > "$MOCK_DIR/copilot" << 'EOF'
#!/bin/bash
echo "something went wrong" >&2
exit 2
EOF
    chmod +x "$MOCK_DIR/copilot"
}

# Helper to write input JSON to a tmpfile and run the script
run_script_with_input() {
    local input="$1"
    echo "$input" > "$TMP_DIR/input.json"
    run bash -c "'$SCRIPT' < '$TMP_DIR/input.json'"
}

# Helper to build sample input and run the script (deduplicates the common 3-line pattern)
run_with_sample_input() {
    local timeout="${1:-5}"
    local input
    input=$(jq -n --argjson findings "$(sample_findings)" --arg diff "$(sample_diff)" --argjson timeout_seconds "$timeout" '$ARGS.named')
    run_script_with_input "$input"
}

# Helper to build a sample findings JSON
sample_findings() {
    cat << 'JSON'
[{"id":1,"agent":"security","type":"blocking","file":"src/auth.ts","line":42,"description":"SQL injection","proposed_fix":"Use parameterized queries","confidence":75},{"id":2,"agent":"correctness","type":"suggestion","file":"src/utils.ts","line":10,"description":"Unchecked null","proposed_fix":"Add null check","confidence":60}]
JSON
}

sample_diff() {
    printf '%s\n' \
        'diff --git a/src/auth.ts b/src/auth.ts' \
        '--- a/src/auth.ts' \
        '+++ b/src/auth.ts' \
        '@@ -40,3 +40,5 @@' \
        ' function login(user) {' \
        '+  db.query("SELECT * FROM users WHERE name = " + user);' \
        '+  return true;' \
        ' }'
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "copilot-meta-review: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "copilot-meta-review: uses set -euo pipefail" {
    run bash -c "head -20 '$SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "copilot-meta-review: sources copilot-helpers.sh" {
    run bash -c "grep -q 'copilot-helpers.sh' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "copilot-meta-review: has main function" {
    run bash -c "grep -q '^main()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "copilot-meta-review: has build_meta_review_prompt function" {
    run bash -c "grep -q '^build_meta_review_prompt()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "copilot-meta-review: has parse_structured_response function" {
    run bash -c "grep -q '^parse_structured_response()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "copilot-meta-review: has parse_freeform_fallback function" {
    run bash -c "grep -q '^parse_freeform_fallback()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Copilot unavailable tests
# =============================================================================

@test "copilot-meta-review: returns available false when copilot not installed" {
    # Override PATH to only include essentials, excluding the real copilot
    local input
    input=$(jq -n --argjson findings "$(sample_findings)" --arg diff "$(sample_diff)" '$ARGS.named')
    echo "$input" > "$TMP_DIR/input.json"
    run bash -c "PATH='/usr/bin:/bin:$MOCK_DIR' '$SCRIPT' < '$TMP_DIR/input.json'"
    [ "$status" -eq 0 ]
    local available
    available=$(echo "$output" | jq -r '.available')
    [ "$available" = "false" ]
}

# =============================================================================
# Empty findings tests
# =============================================================================

@test "copilot-meta-review: returns empty results for empty findings array" {
    create_mock_copilot '"unused"'
    local input
    input=$(jq -n --argjson findings '[]' --arg diff "$(sample_diff)" '$ARGS.named')
    run_script_with_input "$input"
    [ "$status" -eq 0 ]
    local available validations missed
    available=$(echo "$output" | jq -r '.available')
    validations=$(echo "$output" | jq '.validations | length')
    missed=$(echo "$output" | jq '.missed_issues | length')
    [ "$available" = "true" ]
    [ "$validations" -eq 0 ]
    [ "$missed" -eq 0 ]
}

# =============================================================================
# Successful structured output tests
# =============================================================================

@test "copilot-meta-review: parses structured JSON response" {
    local copilot_response='"{\"validations\":[{\"finding_id\":1,\"verdict\":\"CONFIRMED\",\"reasoning\":\"Real issue\"}],\"missed_issues\":[]}"'
    create_mock_copilot "$copilot_response"
    run_with_sample_input
    [ "$status" -eq 0 ]

    local available timed_out verdict
    available=$(echo "$output" | jq -r '.available')
    timed_out=$(echo "$output" | jq -r '.timed_out')
    verdict=$(echo "$output" | jq -r '.validations[0].verdict')
    [ "$available" = "true" ]
    [ "$timed_out" = "false" ]
    [ "$verdict" = "CONFIRMED" ]
}

@test "copilot-meta-review: parses missed issues from response" {
    local copilot_response='"{\"validations\":[],\"missed_issues\":[{\"file\":\"src/new.ts\",\"line\":5,\"type\":\"blocking\",\"description\":\"Buffer overflow\"}]}"'
    create_mock_copilot "$copilot_response"
    run_with_sample_input
    [ "$status" -eq 0 ]

    local missed_count missed_file
    missed_count=$(echo "$output" | jq '.missed_issues | length')
    missed_file=$(echo "$output" | jq -r '.missed_issues[0].file')
    [ "$missed_count" -eq 1 ]
    [ "$missed_file" = "src/new.ts" ]
}

# =============================================================================
# Timeout tests
# =============================================================================

@test "copilot-meta-review: handles timeout correctly" {
    create_timeout_mock_copilot
    run_with_sample_input 1
    [ "$status" -eq 0 ]

    local available timed_out
    available=$(echo "$output" | jq -r '.available')
    timed_out=$(echo "$output" | jq -r '.timed_out')
    [ "$available" = "true" ]
    [ "$timed_out" = "true" ]
}

# =============================================================================
# Error handling tests
# =============================================================================

@test "copilot-meta-review: handles copilot error gracefully" {
    create_error_mock_copilot
    run_with_sample_input
    [ "$status" -eq 0 ]

    local available error
    available=$(echo "$output" | jq -r '.available')
    error=$(echo "$output" | jq -r '.error')
    [ "$available" = "true" ]
    [ "$error" = "copilot exited with error" ]
}

# =============================================================================
# Diff size limit tests
# =============================================================================

@test "copilot-meta-review: still validates findings when diff exceeds size limit" {
    local copilot_response='"{\"validations\":[{\"finding_id\":1,\"verdict\":\"CONFIRMED\",\"reasoning\":\"Confirmed without diff\"}],\"missed_issues\":[]}"'
    create_mock_copilot "$copilot_response"

    # Generate a diff larger than COPILOT_MAX_DIFF_BYTES (102400)
    local large_diff
    large_diff=$(python3 -c "print('x' * 110000)")

    local input
    input=$(jq -n --argjson findings "$(sample_findings)" --arg diff "$large_diff" --argjson timeout_seconds 5 '$ARGS.named')
    run_script_with_input "$input"
    [ "$status" -eq 0 ]

    local available verdict
    available=$(echo "$output" | jq -r '.available')
    verdict=$(echo "$output" | jq -r '.validations[0].verdict')
    [ "$available" = "true" ]
    [ "$verdict" = "CONFIRMED" ]
}

# =============================================================================
# Freeform fallback tests
# =============================================================================

@test "copilot-meta-review: falls back to freeform parsing when JSON invalid" {
    local freeform_text='"#1: CONFIRMED - The SQL injection is real and dangerous\n#2: DISMISSED - The null check exists upstream"'
    create_mock_copilot "$freeform_text"
    run_with_sample_input
    [ "$status" -eq 0 ]

    local available validations_count
    available=$(echo "$output" | jq -r '.available')
    validations_count=$(echo "$output" | jq '.validations | length')
    [ "$available" = "true" ]
    [ "$validations_count" -ge 1 ]
}

# =============================================================================
# Output structure tests
# =============================================================================

@test "copilot-meta-review: output always has required fields" {
    create_mock_copilot '"{\"validations\":[],\"missed_issues\":[]}"'
    run_with_sample_input
    [ "$status" -eq 0 ]

    echo "$output" | jq -e 'has("available")' > /dev/null
    echo "$output" | jq -e 'has("timed_out")' > /dev/null
    echo "$output" | jq -e 'has("validations")' > /dev/null
    echo "$output" | jq -e 'has("missed_issues")' > /dev/null
    echo "$output" | jq -e 'has("duration_ms")' > /dev/null
}

@test "copilot-meta-review: duration_ms is a number" {
    create_mock_copilot '"{\"validations\":[],\"missed_issues\":[]}"'
    run_with_sample_input
    [ "$status" -eq 0 ]

    local duration_type
    duration_type=$(echo "$output" | jq -r '.duration_ms | type')
    [ "$duration_type" = "number" ]
}
