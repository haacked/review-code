#!/usr/bin/env bats
# Tests for check-diff-coverage.sh
#
# The script exists because the truncation guard in the agent prompt is
# advisory: it only helps an agent that reads with Read and compares counts.
# These tests pin that both access paths are counted and that a short read is
# reported rather than passed over.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/check-diff-coverage.sh"

    ROOT="$BATS_TEST_TMPDIR/projects"
    SESSION="11111111-2222-3333-4444-555555555555"
    SUBS="$ROOT/some-project/$SESSION/subagents"
    mkdir -p "$SUBS"
}

# Write one subagent transcript. $1 agent type, $2 name, remaining args are
# tool_use blocks already rendered as JSON.
make_agent() {
    local atype="$1" name="$2"
    shift 2
    jq -n --arg t "$atype" '{agentType: $t}' > "$SUBS/$name.meta.json"
    : > "$SUBS/$name.jsonl"
    local block
    for block in "$@"; do
        jq -nc --argjson b "$block" '{message: {role: "assistant", content: [$b]}}' >> "$SUBS/$name.jsonl"
    done
}

read_block() { # $1 path, $2 offset (or null), $3 limit (or null)
    jq -nc --arg p "$1" --argjson o "$2" --argjson l "$3" \
        '{type: "tool_use", name: "Read", input: ({file_path: $p}
          + (if $o == null then {} else {offset: $o} end)
          + (if $l == null then {} else {limit: $l} end))}'
}

bash_block() { jq -nc --arg c "$1" '{type: "tool_use", name: "Bash", input: {command: $c}}'; }

run_cov() { run "$SCRIPT" --dir "$ROOT" --session "$SESSION" "$@"; }

# =============================================================================
# Structure
# =============================================================================

@test "check-diff-coverage: has correct shebang" {
    run head -1 "$SCRIPT"
    [ "$output" = "#!/usr/bin/env bash" ]
}

@test "check-diff-coverage: uses set -euo pipefail" {
    run grep -q 'set -euo pipefail' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "check-diff-coverage: requires --diff-lines" {
    run "$SCRIPT" --dir "$ROOT" --session "$SESSION"
    [ "$status" -ne 0 ]
}

@test "check-diff-coverage: errors when the session has no transcripts" {
    run "$SCRIPT" --dir "$ROOT" --session "no-such-session" --diff-lines 100
    [ "$status" -ne 0 ]
}

# =============================================================================
# Counting what the agent read
# =============================================================================

@test "check-diff-coverage: counts a single full Read as complete coverage" {
    make_agent code-reviewer-security a1 "$(read_block /tmp/diff.patch null null)"
    run_cov --diff-lines 500 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
    [ "$(echo "$output" | jq -r '.below_threshold | length')" -eq 0 ]
}

@test "check-diff-coverage: a default Read stops at 2000 lines" {
    # Read's default limit is what makes a long diff silently truncate.
    make_agent code-reviewer-security a1 "$(read_block /tmp/diff.patch null null)"
    run_cov --diff-lines 4000 --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 2000 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 50 ]
}

@test "check-diff-coverage: counts sed ranges run through Bash" {
    make_agent code-reviewer-testing a1 \
        "$(bash_block "sed -n '1,300p' /tmp/diff.patch")" \
        "$(bash_block "sed -n '301,600p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "sed" ]
}

@test "check-diff-coverage: counts Read and sed together" {
    make_agent code-reviewer-correctness a1 \
        "$(read_block /tmp/diff.patch 1 200)" \
        "$(bash_block "sed -n '201,400p' /tmp/diff.patch")"
    run_cov --diff-lines 400 --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "Read+sed" ]
}

@test "check-diff-coverage: overlapping ranges are not double counted" {
    make_agent code-reviewer-security a1 \
        "$(bash_block "sed -n '1,300p' /tmp/diff.patch")" \
        "$(bash_block "sed -n '200,400p' /tmp/diff.patch")"
    run_cov --diff-lines 800 --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 400 ]
}

@test "check-diff-coverage: reads past the diff end do not inflate coverage" {
    make_agent code-reviewer-security a1 "$(bash_block "sed -n '1,9999p' /tmp/diff.patch")"
    run_cov --diff-lines 500 --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 500 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: reports the ranges an agent never read" {
    make_agent code-reviewer-testing a1 "$(bash_block "sed -n '301,600p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents[0].unread_ranges[0][0]')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.agents[0].unread_ranges[0][1]')" -eq 300 ]
}

@test "check-diff-coverage: an agent that read nothing reports zero" {
    make_agent code-reviewer-security a1 "$(bash_block "grep -n foo /tmp/other.txt")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "none" ]
}

# =============================================================================
# Threshold and scope
# =============================================================================

@test "check-diff-coverage: flags agents under --min-pct" {
    make_agent code-reviewer-security full "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    make_agent code-reviewer-testing short "$(bash_block "sed -n '1,300p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --min-pct 90 --json
    [ "$(echo "$output" | jq -r '.below_threshold | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.below_threshold[0].agent')" = "code-reviewer-testing" ]
}

@test "check-diff-coverage: --min-pct 0 flags nobody" {
    make_agent code-reviewer-testing short "$(bash_block "sed -n '1,60p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --min-pct 0 --json
    [ "$(echo "$output" | jq -r '.below_threshold | length')" -eq 0 ]
}

@test "check-diff-coverage: ignores non-reviewer subagents" {
    make_agent code-review-context-explorer explorer "$(bash_block "sed -n '1,10p' /tmp/diff.patch")"
    make_agent code-reviewer-security rev "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.agents[0].agent')" = "code-reviewer-security" ]
}

@test "check-diff-coverage: skips transcripts with no meta file" {
    make_agent code-reviewer-security rev "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    : > "$SUBS/orphan.jsonl"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents | length')" -eq 1 ]
}

@test "check-diff-coverage: survives a malformed transcript line" {
    make_agent code-reviewer-security rev "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    echo 'not json at all' >> "$SUBS/rev.jsonl"
    run_cov --diff-lines 600 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: session defaults to CLAUDE_CODE_SESSION_ID" {
    make_agent code-reviewer-security rev "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    CLAUDE_CODE_SESSION_ID="$SESSION" run "$SCRIPT" --dir "$ROOT" --diff-lines 600 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

# =============================================================================
# Table output
# =============================================================================

@test "check-diff-coverage: table names the agents below threshold" {
    make_agent code-reviewer-testing short "$(bash_block "sed -n '1,60p' /tmp/diff.patch")"
    run_cov --diff-lines 600
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "code-reviewer-testing"
    echo "$output" | grep -q "Below 90%"
}

@test "check-diff-coverage: table says so when everyone read enough" {
    make_agent code-reviewer-security full "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    run_cov --diff-lines 600
    echo "$output" | grep -q "Every agent read at least"
}
