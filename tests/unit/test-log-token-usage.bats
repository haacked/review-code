#!/usr/bin/env bats
# Tests for log-token-usage.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/log-token-usage.sh"

    # Create a temporary directory structure for reviews
    REVIEWS_DIR="$BATS_TEST_TMPDIR/reviews"
    REVIEW_FILE="$REVIEWS_DIR/org/repo/pr-123.md"
    mkdir -p "$(dirname "$REVIEW_FILE")"
    touch "$REVIEW_FILE"
    export REVIEWS_DIR REVIEW_FILE
}

teardown() {
    rm -rf "$REVIEWS_DIR"
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "log-token-usage: script exists and is executable" {
    [ -f "$SCRIPT" ]
    [ -x "$SCRIPT" ]
}

@test "log-token-usage: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "log-token-usage: uses set -euo pipefail" {
    run bash -c "head -10 '$SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Input validation tests
# =============================================================================

@test "log-token-usage: requires --review-file argument" {
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"review-file"* ]]
}

@test "log-token-usage: rejects invalid --usage JSON" {
    run "$SCRIPT" --review-file "$REVIEW_FILE" --usage "not json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"JSON"* ]]
}

# =============================================================================
# File creation and append tests
# =============================================================================

@test "log-token-usage: creates log file if it doesn't exist" {
    local usage='{"code-reviewer-security": 45000, "code-reviewer-testing": 50000}'

    run "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "testorg" \
        --repo "testrepo" \
        --mode "pr" \
        --identifier "123"

    [ "$status" -eq 0 ]

    local log_file="$REVIEWS_DIR/token-usage.jsonl"
    [ -f "$log_file" ]
}

@test "log-token-usage: appends to existing log file" {
    local usage='{"code-reviewer-security": 45000, "code-reviewer-testing": 50000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    # First append
    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org1" \
        --repo "repo1" \
        --mode "pr" \
        --identifier "123"

    # Second append with different data
    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org2" \
        --repo "repo2" \
        --mode "pr" \
        --identifier "456"

    # Should have exactly 2 lines
    local line_count=$(wc -l < "$log_file")
    [ "$line_count" -eq 2 ]
}

@test "log-token-usage: does not truncate file on subsequent runs" {
    local usage='{"code-reviewer-security": 45000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    # First write
    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "123"

    local first_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null)

    # Second write
    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "456"

    local second_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null)

    # Size should increase (appended, not truncated)
    [ "$second_size" -gt "$first_size" ]
}

# =============================================================================
# JSON output format tests
# =============================================================================

@test "log-token-usage: outputs valid JSON per line" {
    local usage='{"code-reviewer-security": 45000, "code-reviewer-testing": 50000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "testorg" \
        --repo "testrepo" \
        --mode "pr" \
        --identifier "123"

    # Verify each line is valid JSON
    run bash -c "cat '$log_file' | jq empty"
    [ "$status" -eq 0 ]
}

@test "log-token-usage: preserves org field" {
    local usage='{"code-reviewer-security": 45000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "my-org" \
        --repo "my-repo" \
        --mode "pr" \
        --identifier "789"

    run bash -c "cat '$log_file' | jq -r '.org'"
    [ "$status" -eq 0 ]
    [[ "$output" == "my-org" ]]
}

@test "log-token-usage: preserves repo field" {
    local usage='{"code-reviewer-security": 45000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "my-repo" \
        --mode "pr" \
        --identifier "789"

    run bash -c "cat '$log_file' | jq -r '.repo'"
    [ "$status" -eq 0 ]
    [[ "$output" == "my-repo" ]]
}

# =============================================================================
# Token count population tests (THE KEY TESTS - fix for today's bug)
# =============================================================================

@test "log-token-usage: agents_run defaults to count of agents with usage" {
    local usage='{"code-reviewer-security": 45000, "code-reviewer-testing": 50000, "code-reviewer-performance": 30000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "123"

    run bash -c "cat '$log_file' | jq -r '.agents_run'"
    [ "$status" -eq 0 ]

    # Should default to 3 (number of agents in usage map)
    [ "$output" -eq 3 ]
}

# voice-lint is a script, not an agent: it reports counts and zero tokens.
# Counting it would report one more agent step than actually ran.
@test "log-token-usage: agents_run skips steps that consumed no tokens" {
    local usage='{"code-reviewer-security": 45000, "voice-lint": {"total_tokens": 0, "reverted": 1}}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" --review-file "$REVIEW_FILE" --usage "$usage" --org "org" --repo "repo"

    run bash -c "cat '$log_file' | jq -r '.agents_run'"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

# A revert count is only useful compared across runs, so it has to reach the
# log; the normalization to {total_tokens, tool_uses} used to drop it.
@test "log-token-usage: keeps per-step counters the normalization would drop" {
    local usage='{"voice-lint": {"total_tokens": 0, "checked": 9, "reverted": 2}, "comprehension-gate": {"total_tokens": 5000, "validation_failures": 1}}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" --review-file "$REVIEW_FILE" --usage "$usage" --org "org" --repo "repo"

    run bash -c "cat '$log_file' | jq -r '.counters[\"voice-lint\"].reverted'"
    [ "$output" -eq 2 ]
    run bash -c "cat '$log_file' | jq -r '.counters[\"comprehension-gate\"].validation_failures'"
    [ "$output" -eq 1 ]

    # The token fields keep their existing shape so bin/token-report is unaffected.
    run bash -c "cat '$log_file' | jq -r '.agents[\"comprehension-gate\"]'"
    [ "$output" -eq 5000 ]
}

@test "log-token-usage: omits counters when no step reported one" {
    local usage='{"code-reviewer-security": 45000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" --review-file "$REVIEW_FILE" --usage "$usage" --org "org" --repo "repo"

    run bash -c "cat '$log_file' | jq -r 'has(\"counters\")'"
    [[ "$output" == "false" ]]
}

@test "log-token-usage: agents_run accepts explicit value" {
    local usage='{"code-reviewer-security": 45000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --agents-run 5 \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "123"

    run bash -c "cat '$log_file' | jq -r '.agents_run'"
    [ "$status" -eq 0 ]
    [ "$output" -eq 5 ]
}

@test "log-token-usage: total_tokens is computed from usage sum" {
    local usage='{"code-reviewer-security": 45000, "code-reviewer-testing": 50000, "code-reviewer-performance": 30000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "123"

    run bash -c "cat '$log_file' | jq -r '.total_tokens'"
    [ "$status" -eq 0 ]

    # Must be sum of agent tokens: 45000 + 50000 + 30000 = 125000
    [ "$output" -eq 125000 ]
}

@test "log-token-usage: total_tokens is non-zero when agents ran" {
    local usage='{"context-explorer": 25000, "code-reviewer-security": 45000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "123"

    run bash -c "cat '$log_file' | jq -r '.total_tokens'"
    [ "$status" -eq 0 ]

    # Must be non-zero
    [ "$output" -gt 0 ]
    [ "$output" -eq 70000 ]
}

@test "log-token-usage: correctly aggregates agent token counts" {
    local usage='{"code-reviewer-security": 45000, "code-reviewer-testing": 50000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "123"

    run bash -c "cat '$log_file' | jq '.agents | keys'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"code-reviewer-security"* ]]
    [[ "$output" == *"code-reviewer-testing"* ]]
}

@test "log-token-usage: preserves per-agent token breakdown" {
    local usage='{"code-reviewer-security": 45000, "code-reviewer-testing": 50000}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "123"

    run bash -c "cat '$log_file' | jq '.agents[\"code-reviewer-security\"]'"
    [ "$status" -eq 0 ]
    [ "$output" -eq 45000 ]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "log-token-usage: handles empty usage map" {
    local usage='{}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "123"

    run bash -c "cat '$log_file' | jq '.total_tokens'"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

@test "log-token-usage: accepts object-shaped usage values" {
    local usage='{"code-reviewer-security": {"total_tokens": 45000, "tool_uses": 5}}'
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage "$usage" \
        --org "org" \
        --repo "repo" \
        --mode "pr" \
        --identifier "123"

    run bash -c "cat '$log_file' | jq '.total_tokens'"
    [ "$status" -eq 0 ]
    [ "$output" -eq 45000 ]

    run bash -c "cat '$log_file' | jq '.total_tool_uses'"
    [ "$status" -eq 0 ]
    [ "$output" -eq 5 ]
}

@test "log-token-usage: records the incremental path when given --review-mode" {
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage '{"code-reviewer-security": 45000}' \
        --org "org" --repo "repo" --mode "pr" --identifier "123" \
        --review-mode "delta" --delta-from "abc123"

    # Without these two fields a delta re-review is indistinguishable from a
    # full one in the log, which is the comparison the log exists to support.
    run bash -c "cat '$log_file' | jq -r '.review_mode'"
    [ "$output" = "delta" ]
    run bash -c "cat '$log_file' | jq -r '.delta_from'"
    [ "$output" = "abc123" ]
}

@test "log-token-usage: omits the delta fields on a full review" {
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage '{"code-reviewer-security": 45000}' \
        --org "org" --repo "repo" --mode "pr" --identifier "123"

    run bash -c "cat '$log_file' | jq -r 'has(\"review_mode\")'"
    [ "$output" = "false" ]
    run bash -c "cat '$log_file' | jq -r 'has(\"delta_from\")'"
    [ "$output" = "false" ]
}

# =============================================================================
# Multiple record append tests
# =============================================================================

@test "log-token-usage: appends multiple records and maintains JSON validity" {
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage '{"code-reviewer-security": 100000}' \
        --org "org1" \
        --repo "repo1" \
        --mode "pr" \
        --identifier "123"

    "$SCRIPT" \
        --review-file "$REVIEW_FILE" \
        --usage '{"code-reviewer-security": 150000, "code-reviewer-testing": 100000}' \
        --org "org2" \
        --repo "repo2" \
        --mode "pr" \
        --identifier "456"

    # Verify all lines are valid JSON
    run bash -c "cat '$log_file' | jq -c '.org'"
    [ "$status" -eq 0 ]

    # Should have 2 lines with different orgs
    [[ "$output" == *"org1"* ]]
    [[ "$output" == *"org2"* ]]
}

@test "log-token-usage: records accumulate with different token counts" {
    local log_file="$REVIEWS_DIR/token-usage.jsonl"

    # Write 3 records with different token counts
    for i in 1 2 3; do
        local tokens=$((i * 50000))
        "$SCRIPT" \
            --review-file "$REVIEW_FILE" \
            --usage "{\"reviewer-$i\": $tokens}" \
            --org "org$i" \
            --repo "repo$i" \
            --mode "pr" \
            --identifier "$(( 100 + i ))"
    done

    # Count lines
    local line_count=$(wc -l < "$log_file")
    [ "$line_count" -eq 3 ]
}
