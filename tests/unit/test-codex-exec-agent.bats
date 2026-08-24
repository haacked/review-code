#!/usr/bin/env bats
# Tests for codex-exec-agent.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/helpers/codex-exec-agent.sh"

    MOCK_DIR=$(mktemp -d)
    TMP_DIR=$(mktemp -d)
    export PATH="$MOCK_DIR:$PATH"

    # The script resolves rendered agents under $CODEX_HOME/agents, so scope it
    # to a temp dir instead of the host's real Codex install.
    CODEX_HOME="$TMP_DIR/codex-home"
    export CODEX_HOME
    mkdir -p "$CODEX_HOME/agents"

    PROMPT_FILE="$TMP_DIR/prompt.md"
    OUTPUT_FILE="$TMP_DIR/out/findings.md"
    echo "Review the diff." > "$PROMPT_FILE"

    CODEX_ARGS_LOG="$TMP_DIR/codex-args.log"
    export CODEX_ARGS_LOG
    CODEX_PROMPT_LOG="$TMP_DIR/codex-prompt.log"
    export CODEX_PROMPT_LOG
}

teardown() {
    rm -rf "$MOCK_DIR" "$TMP_DIR"
}

# Write a rendered agent TOML the way bin/render-codex-agents.py does: JSON
# string literals, so developer_instructions carries \n escapes rather than
# real newlines.
write_agent_toml() {
    # write_agent_toml NAME [MODEL] [EFFORT]
    local name="$1"
    local model="${2:-}"
    local effort="${3:-}"
    {
        echo "# Managed by bin/install-codex.sh from the review-code repo."
        echo "name = \"$name\""
        echo "description = \"Test agent $name\""
        if [ -n "$model" ]; then
            echo "model = \"$model\""
            echo "model_reasoning_effort = \"$effort\""
        fi
        echo "developer_instructions = \"You are $name.\\n\\nFind real bugs.\\n\""
    } > "$CODEX_HOME/agents/$name.toml"
}

# A stub codex that logs its flags one per line and the prompt separately, so
# assertions can tell an exact flag from a substring of the prompt body.
create_mock_codex() {
    local exit_code="${1:-0}"
    cat > "$MOCK_DIR/codex" << MOCKEOF
#!/usr/bin/env bash
# Generated stub codex executable; see tests/unit/test-codex-exec-agent.bats.
printf '%s\n' "\${@:1:\$# - 1}" > "\$CODEX_ARGS_LOG"
printf '%s' "\${!#}" > "\$CODEX_PROMPT_LOG"
exit $exit_code
MOCKEOF
    chmod +x "$MOCK_DIR/codex"
}

@test "codex-exec-agent: has correct shebang" {
    run head -1 "$SCRIPT"
    [ "$output" = "#!/usr/bin/env bash" ]
}

@test "codex-exec-agent: uses set -euo pipefail" {
    run grep -q "set -euo pipefail" "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "codex-exec-agent: script exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "codex-exec-agent: rejects wrong argument count" {
    run "$SCRIPT" only-one-arg
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "codex-exec-agent: errors when the prompt file is missing" {
    write_agent_toml code-reviewer-security gpt-5.6-sol high
    create_mock_codex
    run "$SCRIPT" code-reviewer-security "$TMP_DIR/absent.md" "$OUTPUT_FILE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"prompt file not found"* ]]
}

@test "codex-exec-agent: errors when the agent has no rendered TOML" {
    create_mock_codex
    run "$SCRIPT" never-rendered "$PROMPT_FILE" "$OUTPUT_FILE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"never-rendered"* ]]
    [ ! -f "$CODEX_ARGS_LOG" ]
}

@test "codex-exec-agent: errors when the agent TOML carries no instructions" {
    write_agent_toml hollow gpt-5.6-sol high
    # A hand-written TOML in the shared agents directory can use syntax the
    # renderer never emits; running it with no instructions would look like a
    # finished review, so the dispatch has to stop.
    grep -v "^developer_instructions" "$CODEX_HOME/agents/hollow.toml" > "$TMP_DIR/hollow.toml"
    mv "$TMP_DIR/hollow.toml" "$CODEX_HOME/agents/hollow.toml"
    create_mock_codex
    run "$SCRIPT" hollow "$PROMPT_FILE" "$OUTPUT_FILE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"developer_instructions"* ]]
    [ ! -f "$CODEX_ARGS_LOG" ]
}

@test "codex-exec-agent: passes the agent's model and reasoning effort" {
    write_agent_toml code-reviewer-security gpt-5.6-sol high
    create_mock_codex
    run "$SCRIPT" code-reviewer-security "$PROMPT_FILE" "$OUTPUT_FILE"
    [ "$status" -eq 0 ]
    grep -Fxq -- "--model" "$CODEX_ARGS_LOG"
    grep -Fxq -- "gpt-5.6-sol" "$CODEX_ARGS_LOG"
    grep -Fxq -- "model_reasoning_effort=high" "$CODEX_ARGS_LOG"
}

@test "codex-exec-agent: omits model flags for an inherit-model agent" {
    write_agent_toml code-reviewer-voice
    create_mock_codex
    run "$SCRIPT" code-reviewer-voice "$PROMPT_FILE" "$OUTPUT_FILE"
    [ "$status" -eq 0 ]
    run grep -Fxq -- "--model" "$CODEX_ARGS_LOG"
    [ "$status" -ne 0 ]
    run grep -Fq -- "model_reasoning_effort" "$CODEX_ARGS_LOG"
    [ "$status" -ne 0 ]
}

@test "codex-exec-agent: keeps the read-only sandbox and findings-file flags" {
    write_agent_toml code-reviewer-security gpt-5.6-sol high
    create_mock_codex
    run "$SCRIPT" code-reviewer-security "$PROMPT_FILE" "$OUTPUT_FILE"
    [ "$status" -eq 0 ]
    grep -Fxq -- "--json" "$CODEX_ARGS_LOG"
    grep -Fxq -- "read-only" "$CODEX_ARGS_LOG"
    grep -Fxq -- "--output-last-message" "$CODEX_ARGS_LOG"
    grep -Fxq -- "$OUTPUT_FILE" "$CODEX_ARGS_LOG"
}

@test "codex-exec-agent: prepends developer_instructions to the prompt" {
    write_agent_toml code-reviewer-security gpt-5.6-sol high
    create_mock_codex
    run "$SCRIPT" code-reviewer-security "$PROMPT_FILE" "$OUTPUT_FILE"
    [ "$status" -eq 0 ]
    # The instructions lead, the prompt body follows, and the \n escapes the
    # renderer wrote arrive as real line breaks.
    [ "$(head -1 "$CODEX_PROMPT_LOG")" = "You are code-reviewer-security." ]
    grep -Fxq "Find real bugs." "$CODEX_PROMPT_LOG"
    grep -Fxq "Review the diff." "$CODEX_PROMPT_LOG"
    run grep -Fq '\n' "$CODEX_PROMPT_LOG"
    [ "$status" -ne 0 ]
}

@test "codex-exec-agent: creates the output file's parent directory" {
    write_agent_toml code-reviewer-security gpt-5.6-sol high
    create_mock_codex
    run "$SCRIPT" code-reviewer-security "$PROMPT_FILE" "$OUTPUT_FILE"
    [ "$status" -eq 0 ]
    [ -d "$(dirname "$OUTPUT_FILE")" ]
}

@test "codex-exec-agent: mirrors codex's exit code" {
    write_agent_toml code-reviewer-security gpt-5.6-sol high
    create_mock_codex 3
    run "$SCRIPT" code-reviewer-security "$PROMPT_FILE" "$OUTPUT_FILE"
    [ "$status" -eq 3 ]
}
