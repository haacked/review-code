#!/usr/bin/env bats
# Tests for codex-meta-review.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/codex-meta-review.sh"

    # Create temp directory for mock scripts and test data
    MOCK_DIR=$(mktemp -d)
    TMP_DIR=$(mktemp -d)
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$MOCK_DIR" "$TMP_DIR"
}

# Helper to build a codex `item.completed`/`agent_message` JSONL line for the given text
codex_agent_message_line() {
    local text="$1"
    jq -nc --arg text "$text" '{type: "item.completed", item: {id: "item_1", type: "agent_message", text: $text}}'
}

# Helper to create a mock codex that returns structured JSON as its final agent message
create_mock_codex() {
    local response="$1"
    cat > "$MOCK_DIR/codex" << MOCKEOF
#!/bin/bash
echo '{"type":"thread.started"}'
echo '$(codex_agent_message_line "${response}")'
echo '{"type":"turn.completed"}'
MOCKEOF
    chmod +x "$MOCK_DIR/codex"
}

# Helper to create a mock codex that times out (exit 124)
create_timeout_mock_codex() {
    cat > "$MOCK_DIR/codex" << 'EOF'
#!/bin/bash
exit 124
EOF
    chmod +x "$MOCK_DIR/codex"
}

# Helper to create a mock codex that errors (exit 2)
create_error_mock_codex() {
    cat > "$MOCK_DIR/codex" << 'EOF'
#!/bin/bash
echo "something went wrong" >&2
exit 2
EOF
    chmod +x "$MOCK_DIR/codex"
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

@test "codex-meta-review: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "codex-meta-review: uses set -euo pipefail" {
    run bash -c "head -20 '$SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "codex-meta-review: sources codex-helpers.sh" {
    run bash -c "grep -q 'codex-helpers.sh' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "codex-meta-review: sources meta-review-shared.sh" {
    run bash -c "grep -q 'meta-review-shared.sh' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "codex-meta-review: has main function" {
    run bash -c "grep -q '^main()' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "codex-meta-review: shared helper has build_meta_review_prompt function" {
    run bash -c "grep -q '^build_meta_review_prompt()' '$PROJECT_ROOT/skills/review-code/scripts/helpers/meta-review-shared.sh'"
    [ "$status" -eq 0 ]
}

@test "codex-meta-review: shared helper has parse_structured_response function" {
    run bash -c "grep -q '^parse_structured_response()' '$PROJECT_ROOT/skills/review-code/scripts/helpers/meta-review-shared.sh'"
    [ "$status" -eq 0 ]
}

@test "codex-meta-review: shared helper has parse_freeform_fallback function" {
    run bash -c "grep -q '^parse_freeform_fallback()' '$PROJECT_ROOT/skills/review-code/scripts/helpers/meta-review-shared.sh'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Codex unavailable tests
# =============================================================================

@test "codex-meta-review: returns available false when codex not installed" {
    # Override PATH to only include essentials, excluding the real codex
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

@test "codex-meta-review: returns empty results for empty findings array" {
    create_mock_codex "unused"
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

@test "codex-meta-review: parses structured JSON response" {
    local codex_response='{"validations":[{"finding_id":1,"verdict":"CONFIRMED","reasoning":"Real issue"}],"missed_issues":[]}'
    create_mock_codex "$codex_response"
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

@test "codex-meta-review: parses missed issues from response" {
    local codex_response='{"validations":[],"missed_issues":[{"file":"src/new.ts","line":5,"type":"blocking","description":"Buffer overflow"}]}'
    create_mock_codex "$codex_response"
    run_with_sample_input
    [ "$status" -eq 0 ]

    local missed_count missed_file
    missed_count=$(echo "$output" | jq '.missed_issues | length')
    missed_file=$(echo "$output" | jq -r '.missed_issues[0].file')
    [ "$missed_count" -eq 1 ]
    [ "$missed_file" = "src/new.ts" ]
}

@test "codex-meta-review: ignores non-agent_message JSONL events" {
    cat > "$MOCK_DIR/codex" << 'MOCKEOF'
#!/bin/bash
echo '{"type":"thread.started"}'
echo '{"type":"item.started","item":{"id":"item_1","type":"command_execution"}}'
echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{\"validations\":[{\"finding_id\":1,\"verdict\":\"CONFIRMED\",\"reasoning\":\"Real SQL injection\"}],\"missed_issues\":[]}"}}'
echo '{"type":"turn.completed"}'
MOCKEOF
    chmod +x "$MOCK_DIR/codex"
    run_with_sample_input
    [ "$status" -eq 0 ]

    local available verdict
    available=$(echo "$output" | jq -r '.available')
    verdict=$(echo "$output" | jq -r '.validations[0].verdict')
    [ "$available" = "true" ]
    [ "$verdict" = "CONFIRMED" ]
}

@test "codex-meta-review: uses the last agent_message when a turn emits several" {
    local first_response='{"validations":[{"finding_id":1,"verdict":"DISMISSED","reasoning":"stale"}],"missed_issues":[]}'
    local second_response='{"validations":[{"finding_id":1,"verdict":"CONFIRMED","reasoning":"final"}],"missed_issues":[]}'
    cat > "$MOCK_DIR/codex" << MOCKEOF
#!/bin/bash
echo '{"type":"thread.started"}'
echo '$(codex_agent_message_line "${first_response}")'
echo '$(codex_agent_message_line "${second_response}")'
echo '{"type":"turn.completed"}'
MOCKEOF
    chmod +x "$MOCK_DIR/codex"
    run_with_sample_input
    [ "$status" -eq 0 ]

    local verdict reasoning
    verdict=$(echo "$output" | jq -r '.validations[0].verdict')
    reasoning=$(echo "$output" | jq -r '.validations[0].reasoning')
    [ "$verdict" = "CONFIRMED" ]
    [ "$reasoning" = "final" ]
}

@test "codex-meta-review: falls back to raw output when no agent_message event is present" {
    cat > "$MOCK_DIR/codex" << 'MOCKEOF'
#!/bin/bash
echo '{"type":"thread.started"}'
echo '{"type":"item.started","item":{"id":"item_1","type":"command_execution"}}'
echo '{"type":"turn.completed"}'
MOCKEOF
    chmod +x "$MOCK_DIR/codex"
    run_with_sample_input
    [ "$status" -eq 0 ]

    local available validations_count
    available=$(echo "$output" | jq -r '.available')
    validations_count=$(echo "$output" | jq '.validations | length')
    [ "$available" = "true" ]
    [ "$validations_count" -eq 0 ]
}

# =============================================================================
# Timeout tests
# =============================================================================

@test "codex-meta-review: handles timeout correctly" {
    create_timeout_mock_codex
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

@test "codex-meta-review: handles codex error gracefully" {
    create_error_mock_codex
    run_with_sample_input
    [ "$status" -eq 0 ]

    local available error
    available=$(echo "$output" | jq -r '.available')
    error=$(echo "$output" | jq -r '.error')
    [ "$available" = "true" ]
    [ "$error" = "codex exited with error" ]
}

# =============================================================================
# Diff size limit tests
# =============================================================================

@test "codex-meta-review: still validates findings when diff exceeds size limit" {
    local codex_response='{"validations":[{"finding_id":1,"verdict":"CONFIRMED","reasoning":"Confirmed without diff"}],"missed_issues":[]}'
    create_mock_codex "$codex_response"

    # Generate a diff larger than CODEX_MAX_DIFF_BYTES (102400)
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

@test "codex-meta-review: falls back to freeform parsing when JSON invalid" {
    local freeform_text='#1: CONFIRMED - The SQL injection is real and dangerous
#2: DISMISSED - The null check exists upstream'
    create_mock_codex "$freeform_text"
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

@test "codex-meta-review: output always has required fields" {
    create_mock_codex '{"validations":[],"missed_issues":[]}'
    run_with_sample_input
    [ "$status" -eq 0 ]

    echo "$output" | jq -e 'has("available")' > /dev/null
    echo "$output" | jq -e 'has("timed_out")' > /dev/null
    echo "$output" | jq -e 'has("validations")' > /dev/null
    echo "$output" | jq -e 'has("missed_issues")' > /dev/null
    echo "$output" | jq -e 'has("duration_ms")' > /dev/null
}

@test "codex-meta-review: duration_ms is a number" {
    create_mock_codex '{"validations":[],"missed_issues":[]}'
    run_with_sample_input
    [ "$status" -eq 0 ]

    local duration_type
    duration_type=$(echo "$output" | jq -r '.duration_ms | type')
    [ "$duration_type" = "number" ]
}
