#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/helpers/agent-dispatch.sh"
    TEST_DIR="$BATS_TEST_TMPDIR/dispatch with spaces"
    TEST_CODEX_HOME="$TEST_DIR/codex home"
    MANIFEST="$TEST_DIR/batch manifest.json"
    export DISPATCH_TEST_DIR="$TEST_DIR"
    mkdir -p "$TEST_DIR/bin" "$TEST_CODEX_HOME/agents" "$TEST_DIR/prompts" "$TEST_DIR/state"
    export PATH="$TEST_DIR/bin:$PATH"
    cat > "$TEST_DIR/bin/codex" << 'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["DISPATCH_TEST_DIR"])
prompt = sys.argv[-1].splitlines()[-1]
spec = json.loads(prompt)
name = spec["name"]
state = root / "state"
(state / f"{name}.started").touch()
deadline = time.monotonic() + 5
while not all((state / f"{peer}.started").exists() for peer in spec.get("peers", [])):
    if time.monotonic() > deadline:
        sys.exit(81)
    time.sleep(0.01)
if spec.get("after"):
    while not (state / f"{spec['after']}.done").exists():
        if time.monotonic() > deadline:
            sys.exit(82)
        time.sleep(0.01)
    time.sleep(0.1)
output = Path(sys.argv[sys.argv.index("--output-last-message") + 1])
output.write_text(f"Findings from {name}.\n")
with (state / "completion-order").open("a") as log:
    log.write(f"{name}\n")
(state / f"{name}.done").touch()
print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 5}}))
sys.exit(spec.get("exit_code", 0))
PY
    chmod +x "$TEST_DIR/bin/codex"
}

write_agent() {
    local name="$1"
    local spec="$2"
    printf 'developer_instructions = "Review the supplied prompt."\n' > "$TEST_CODEX_HOME/agents/$name.toml"
    printf '%s\n' "$spec" > "$TEST_DIR/prompts/$name prompt.md"
}

write_manifest() {
    printf '%s\n' "$@" | jq -Rs --arg dir "$TEST_DIR" '
        split("\n") | map(select(length > 0)) | map({
            agent: .,
            prompt_file: ($dir + "/prompts/" + . + " prompt.md"),
            output_file: ($dir + "/reports/" + . + " output.md")
        })' > "$MANIFEST"
}

dispatch() {
    env -u CLAUDECODE -u CLAUDE_CONFIG_DIR CODEX_HOME="$TEST_CODEX_HOME" "$SCRIPT" "$@"
}

run_batch() {
    local result=0
    dispatch batch "$MANIFEST" || result=$?
    if [[ -f "$TEST_DIR/state/completion-order" ]]; then
        cp "$TEST_DIR/state/completion-order" "$TEST_DIR/completed-at-return"
    fi
    return "$result"
}

@test "agent-dispatch: batch runs concurrently and waits for out-of-order completion with spaced paths" {
    write_agent slow '{"name":"slow","peers":["fast"],"after":"fast"}'
    write_agent fast '{"name":"fast","peers":["slow"]}'
    write_manifest slow fast

    run run_batch

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_DIR/completed-at-return")" = $'fast\nslow' ]
    [ "$(cat "$TEST_DIR/reports/slow output.md")" = 'Findings from slow.' ]
    [ "$(cat "$TEST_DIR/reports/fast output.md")" = 'Findings from fast.' ]
}

@test "agent-dispatch: batch reports an early failure after waiting for successful siblings" {
    write_agent failed '{"name":"failed","peers":["slow"],"exit_code":7}'
    write_agent slow '{"name":"slow","peers":["failed"],"after":"failed"}'
    write_manifest failed slow

    run run_batch

    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: agent failed exited 7: $TEST_DIR/reports/failed output.md"* ]]
    [ "$(cat "$TEST_DIR/completed-at-return")" = $'failed\nslow' ]
    [ "$(cat "$TEST_DIR/reports/slow output.md")" = 'Findings from slow.' ]
}

@test "agent-dispatch: batch catches a failure that finishes after a successful sibling" {
    write_agent fast '{"name":"fast","peers":["failed"]}'
    write_agent failed '{"name":"failed","peers":["fast"],"after":"fast","exit_code":9}'
    write_manifest fast failed

    run run_batch

    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: agent failed exited 9: $TEST_DIR/reports/failed output.md"* ]]
    [ "$(cat "$TEST_DIR/completed-at-return")" = $'fast\nfailed' ]
}

@test "agent-dispatch: documented batch command runs the manifest and waits for both agents" {
    write_agent slow '{"name":"slow","peers":["fast"],"after":"fast"}'
    write_agent fast '{"name":"fast","peers":["slow"]}'
    write_manifest slow fast
    cp "$MANIFEST" "$TEST_DIR/agent-batch.json"
    python3 - "$PROJECT_ROOT/skills/review-code" "$TEST_DIR" << 'PY' > "$TEST_DIR/documented-batch.sh"
from pathlib import Path
import re
import sys

skill, artifacts = sys.argv[1:]
document = (Path(skill) / "handlers/review.md").read_text()
blocks = re.findall(r"^```bash\n(.*?)^```$", document, re.M | re.S)
matches = [block for block in blocks if "agent-dispatch.sh batch" in block]
assert len(matches) == 1
print(matches[0].replace("~/.agents/skills/review-code", skill).replace("<artifacts_dir>", artifacts), end="")
PY
    printf '\ncp "$DISPATCH_TEST_DIR/state/completion-order" "$DISPATCH_TEST_DIR/completed-at-return"\n' >> "$TEST_DIR/documented-batch.sh"

    run env -u CLAUDECODE -u CLAUDE_CONFIG_DIR CODEX_HOME="$TEST_CODEX_HOME" bash -e "$TEST_DIR/documented-batch.sh"

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_DIR/completed-at-return")" = $'fast\nslow' ]
    [ "$(cat "$TEST_DIR/reports/slow output.md")" = 'Findings from slow.' ]
    [ "$(cat "$TEST_DIR/reports/fast output.md")" = 'Findings from fast.' ]
}

@test "agent-dispatch: batch preserves quotes and backslashes in prompt and output paths" {
    local prompt_file="$TEST_DIR/prompts/review's \"quoted\" \\prompt.md"
    local output_file="$TEST_DIR/reports/review's \"quoted\" \\output.md"
    write_agent reviewer '{"name":"reviewer"}'
    mv "$TEST_DIR/prompts/reviewer prompt.md" "$prompt_file"
    jq -n --arg prompt "$prompt_file" --arg output "$output_file" \
        '[{agent: "reviewer", prompt_file: $prompt, output_file: $output}]' > "$MANIFEST"

    run run_batch

    [ "$status" -eq 0 ]
    [ "$(cat "$output_file")" = 'Findings from reviewer.' ]
    [ -f "${output_file}.events.jsonl" ]
}

@test "agent-dispatch: validates every manifest entry before launching any agent" {
    write_agent valid '{"name":"valid"}'
    write_manifest valid
    jq '. + [{agent: "missing-prompt", prompt_file: "/nonexistent/prompt.md", output_file: "unused.md"}]' "$MANIFEST" > "$TEST_DIR/invalid.json"
    mv "$TEST_DIR/invalid.json" "$MANIFEST"

    run run_batch

    [ "$status" -ne 0 ]
    [ ! -e "$TEST_DIR/state/valid.started" ]
}

@test "agent-dispatch: rejects malformed manifests and entries without launching agents" {
    local manifest
    for manifest in 'invalid json' '{}' '[{}]' '[{"agent":42,"prompt_file":"x","output_file":"y"}]' '[{"agent":"x","prompt_file":"x","output_file":""}]'; do
        printf '%s\n' "$manifest" > "$MANIFEST"

        run run_batch

        [ "$status" -ne 0 ]
        [ ! -e "$TEST_DIR/state/completion-order" ]
    done
}

@test "agent-dispatch: rejects duplicate batch output paths before launching agents" {
    write_agent first '{"name":"first"}'
    write_agent second '{"name":"second"}'
    write_manifest first second
    jq '.[1].output_file = .[0].output_file' "$MANIFEST" > "$TEST_DIR/invalid.json"
    mv "$TEST_DIR/invalid.json" "$MANIFEST"

    run run_batch

    [ "$status" -ne 0 ]
    [ ! -e "$TEST_DIR/state/first.started" ]
    [ ! -e "$TEST_DIR/state/second.started" ]
}

@test "agent-dispatch: batch leaves Claude dispatch to its native tools" {
    write_agent reviewer '{"name":"reviewer"}'
    write_manifest reviewer

    run env CLAUDECODE=1 CODEX_HOME="$TEST_CODEX_HOME" "$SCRIPT" batch "$MANIFEST"

    [ "$status" -ne 0 ]
    [[ "$output" == *Claude* ]]
    [ ! -e "$TEST_DIR/state/reviewer.started" ]
}

@test "agent-dispatch: keeps the existing single-agent run command" {
    write_agent reviewer '{"name":"reviewer"}'

    run dispatch run reviewer "$TEST_DIR/prompts/reviewer prompt.md" "$TEST_DIR/reports/reviewer output.md"

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_DIR/reports/reviewer output.md")" = 'Findings from reviewer.' ]
}
