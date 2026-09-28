#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/bin/token-report"
    ROOT="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$ROOT/review-fixture/session/subagents"
    MAIN="$ROOT/review-fixture/session.jsonl"
    python3 - "$MAIN" << 'PY'
import json
import sys

with open(sys.argv[1], "w") as out:
    for i in range(3):
        out.write(json.dumps({"timestamp": "2026-09-01T00:00:00Z", "message": {
            "id": f"m{i}", "role": "assistant", "usage": {"input_tokens": 1}, "content": []
        }}) + "\n")
PY
}

bash_call() {
    jq -nc --arg id "$1" --arg command "$2" \
        '{message: {role: "assistant", content: [{type: "tool_use", id: $id, name: "Bash", input: {command: $command}}]}}' >> "$MAIN"
}

@test "token-report --bash-glue: counts calls once and separates known glue from short work" {
    bash_call t true
    bash_call t true
    bash_call s 'sleep 1'
    bash_call d 'date -u +%Y-%m-%dT%H:%M:%SZ'
    bash_call e 'echo "waiting for background agents"'
    bash_call useful 'git status --short'
    bash_call compound 'true && git status'
    bash_call script 'scripts/review-orchestrator.sh'
    bash_call long 'echo "waiting for background agents to finish their work"'
    printf '%s\n' 'invalid json' >> "$MAIN"
    cp "$MAIN" "$ROOT/review-fixture/session/subagents/agent.jsonl"

    run "$SCRIPT" --dir "$ROOT" --bash-glue --json

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.summary.sessions == 1 and .summary.bash_calls == 8 and .summary.glue_calls == 4 and .summary.glue_calls_per_session == 4 and .summary.short_non_skill_calls == 6 and .summary.by_kind == {noop: 1, sleep: 1, timestamp: 1, waiting: 1}'
}

@test "token-report --bash-glue: includes zero-glue sessions in denominator and respects since" {
    bash_call t true
    sed 's/2026-09-01/2026-08-01/g' "$MAIN" > "$ROOT/review-fixture/old.jsonl"
    sed '/tool_use/d' "$MAIN" > "$ROOT/review-fixture/clean.jsonl"
    mkdir -p "$ROOT/unrelated"
    cp "$MAIN" "$ROOT/unrelated/session.jsonl"

    run "$SCRIPT" --dir "$ROOT" --match review --since 2026-09-01 --bash-glue --json

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.summary.sessions == 2 and .summary.glue_calls == 1 and .summary.glue_calls_per_session == 0.5'
}

@test "token-report --bash-glue: prints the categories in text mode" {
    bash_call t true

    run "$SCRIPT" --dir "$ROOT" --bash-glue

    [ "$status" -eq 0 ]
    [[ "$output" == *"noop"* ]]
    [[ "$output" == *"1.00"* ]]
}

@test "token-report --bash-glue: returns JSON and text summaries for no sessions" {
    rm "$MAIN"

    run "$SCRIPT" --dir "$ROOT" --bash-glue --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.summary.sessions == 0 and .summary.glue_calls_per_session == 0 and .sessions == []'

    run "$SCRIPT" --dir "$ROOT" --bash-glue
    [ "$status" -eq 0 ]
    [[ "$output" == *"Bash glue report: 0 sessions"* ]]
}
