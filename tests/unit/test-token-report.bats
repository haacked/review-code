#!/usr/bin/env bats
# Tests for bin/token-report
#
# This is the tool whose numbers decide whether the cost work paid off, so the
# failure that matters is a silent undercount: a transcript shape it stops
# recognizing yields smaller figures rather than an error. These pin the
# arithmetic (dedup by message id, per-tier rates) and the prompt classifier.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/bin/token-report"

    ROOT="$BATS_TEST_TMPDIR/projects"
    PROJ="$ROOT/review-fixture"
    SESSION="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    mkdir -p "$PROJ/$SESSION/subagents"
    MAIN="$PROJ/$SESSION.jsonl"
    : > "$MAIN"
}

# One assistant turn with a usage block. $1 message id, $2 model, then
# input / cache_write / cache_read / output.
turn() {
    jq -nc --arg id "$1" --arg m "$2" \
        --argjson i "$3" --argjson cw "$4" --argjson cr "$5" --argjson o "$6" \
        '{timestamp: "2026-08-01T00:00:00Z", message: {id: $id, model: $m, usage: {
            input_tokens: $i, cache_creation_input_tokens: $cw,
            cache_read_input_tokens: $cr, output_tokens: $o}}}'
}

report() { run "$SCRIPT" --dir "$ROOT" --match review "$@"; }

# =============================================================================
# Structure
# =============================================================================

@test "token-report: has correct shebang" {
    run head -1 "$SCRIPT"
    [ "$output" = "#!/usr/bin/env python3" ]
}

@test "token-report: is valid Python" {
    run python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "token-report: rejects unknown arguments" {
    run "$SCRIPT" --nonsense
    [ "$status" -ne 0 ]
}

@test "token-report: errors when the transcript directory is missing" {
    run "$SCRIPT" --dir "$BATS_TEST_TMPDIR/nope"
    [ "$status" -ne 0 ]
}

# =============================================================================
# Cost arithmetic
# =============================================================================

@test "token-report: prices opus input and output at the published rates" {
    # 1M input at $15 + 1M output at $75 = $90.
    { turn m1 claude-opus-4 1000000 0 0 1000000
      turn m2 claude-opus-4 0 0 0 0
      turn m3 claude-opus-4 0 0 0 0; } > "$MAIN"
    report --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.sessions[0].orchestrator_usd == 90' > /dev/null
}

@test "token-report: prices cache writes and reads apart from input" {
    # 1M cache-write at $18.75 + 1M cache-read at $1.50 = $20.25.
    { turn m1 claude-opus-4 0 1000000 1000000 0
      turn m2 claude-opus-4 0 0 0 0
      turn m3 claude-opus-4 0 0 0 0; } > "$MAIN"
    report --json
    echo "$output" | jq -e '.sessions[0].orchestrator_usd == 20.25' > /dev/null
}

@test "token-report: prices a cheaper tier by the model in the transcript" {
    # Same tokens as the opus case, at haiku rates: $1 + $5 = $6.
    { turn m1 claude-haiku-4-5 1000000 0 0 1000000
      turn m2 claude-haiku-4-5 0 0 0 0
      turn m3 claude-haiku-4-5 0 0 0 0; } > "$MAIN"
    report --json
    echo "$output" | jq -e '.sessions[0].orchestrator_usd == 6' > /dev/null
}

@test "token-report: counts a repeated message id once" {
    # Each content block repeats the usage object; summing naively overcounts.
    { turn m1 claude-opus-4 1000000 0 0 0
      turn m1 claude-opus-4 1000000 0 0 0
      turn m2 claude-opus-4 0 0 0 0
      turn m3 claude-opus-4 0 0 0 0; } > "$MAIN"
    report --json
    echo "$output" | jq -e '.sessions[0].orchestrator_usd == 15' > /dev/null
    [ "$(echo "$output" | jq -r '.sessions[0].turns')" -eq 3 ]
}

@test "token-report: skips sessions with fewer than three turns" {
    { turn m1 claude-opus-4 1000 0 0 1000
      turn m2 claude-opus-4 1000 0 0 1000; } > "$MAIN"
    report --json
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "No sessions matched"
}

@test "token-report: bills subagents separately from the orchestrator" {
    { turn m1 claude-opus-4 1000000 0 0 0
      turn m2 claude-opus-4 0 0 0 0
      turn m3 claude-opus-4 0 0 0 0; } > "$MAIN"
    turn s1 claude-opus-4 1000000 0 0 0 > "$PROJ/$SESSION/subagents/agent-x.jsonl"
    report --json
    echo "$output" | jq -e '.sessions[0].orchestrator_usd == 15' > /dev/null
    echo "$output" | jq -e '.sessions[0].subagent_usd == 15' > /dev/null
    echo "$output" | jq -e '.sessions[0].total_usd == 30' > /dev/null
    [ "$(echo "$output" | jq -r '.sessions[0].subagents')" -eq 1 ]
}

@test "token-report: survives a malformed transcript line" {
    { turn m1 claude-opus-4 1000000 0 0 0
      echo 'not json'
      turn m2 claude-opus-4 0 0 0 0
      turn m3 claude-opus-4 0 0 0 0; } > "$MAIN"
    report --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.sessions[0].orchestrator_usd == 15' > /dev/null
}

@test "token-report: --match excludes projects that do not match" {
    { turn m1 claude-opus-4 1000 0 0 1000
      turn m2 claude-opus-4 0 0 0 0
      turn m3 claude-opus-4 0 0 0 0; } > "$MAIN"
    run "$SCRIPT" --dir "$ROOT" --match "nothing-matches-this" --json
    echo "$output" | grep -q "No sessions matched"
}

# =============================================================================
# --prompts: how reviewer agents received their payload
# =============================================================================

sub() { # $1 name, $2 agentType, $3 prompt text
    jq -n --arg t "$2" '{agentType: $t}' > "$PROJ/$SESSION/subagents/$1.meta.json"
    jq -nc --arg c "$3" '{message: {role: "user", content: $c}}' \
        > "$PROJ/$SESSION/subagents/$1.jsonl"
}

@test "token-report --prompts: classifies a diff in the prompt as inlined" {
    sub a1 code-reviewer-security "Review this: diff --git a/x.ts b/x.ts"
    report --prompts --json
    [ "$(echo "$output" | jq -r '.by_shape.inlined.n')" -eq 1 ]
}

@test "token-report --prompts: classifies a named file as by-reference" {
    sub a1 code-reviewer-security "Read /tmp/rc-123-agent-context.md first, then review."
    report --prompts --json
    [ "$(echo "$output" | jq -r '.by_shape["by-reference"].n')" -eq 1 ]
}

@test "token-report --prompts: recognizes a path regardless of the filename used" {
    # The orchestrator invented a different name each run before the briefing
    # script standardized one, so the classifier must not key on known names.
    sub a1 code-reviewer-security "Context is at /private/tmp/wherever/made-up-name.md"
    report --prompts --json
    [ "$(echo "$output" | jq -r '.by_shape["by-reference"].n')" -eq 1 ]
}

@test "token-report --prompts: a diff wins over a path when both appear" {
    sub a1 code-reviewer-security "See /tmp/ctx.md and diff --git a/x.ts b/x.ts"
    report --prompts --json
    [ "$(echo "$output" | jq -r '.by_shape.inlined.n')" -eq 1 ]
}

@test "token-report --prompts: classifies neither as no-payload" {
    sub a1 code-reviewer-security "Perform a security review of PR 42 in org/repo."
    report --prompts --json
    [ "$(echo "$output" | jq -r '.by_shape["no-payload"].n')" -eq 1 ]
}

@test "token-report --prompts: ignores non-reviewer subagents" {
    sub a1 code-review-context-explorer "diff --git a/x.ts b/x.ts"
    sub a2 code-reviewer-security "Read /tmp/ctx.md"
    report --prompts --json
    [ "$(echo "$output" | jq -r '.reviewer_dispatches')" -eq 1 ]
}

@test "token-report --prompts: drops the harness placeholder prompt" {
    sub a1 code-reviewer-security "FILE_PROMPT_PLACEHOLDER"
    report --prompts --json
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "No reviewer subagents matched"
}
