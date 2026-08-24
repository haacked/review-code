#!/usr/bin/env bats
# Tests for bin/render-codex-agents.py

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    RENDER="$PROJECT_ROOT/bin/render-codex-agents.py"
    SRC_DIR=$(mktemp -d)
    OUT_DIR=$(mktemp -d)
}

teardown() {
    rm -rf "$SRC_DIR" "$OUT_DIR"
}

write_agent() {
    # write_agent NAME MODEL [COLOR]
    local name="$1"
    local model="$2"
    local color="${3:-}"
    {
        echo "---"
        echo "name: $name"
        echo "description: Test agent $name"
        echo "model: $model"
        if [ -n "$color" ]; then
            echo "color: $color"
        fi
        echo "metadata:"
        echo "  execution-tier: $model-tier"
        echo "---"
        echo ""
        echo "Body for $name."
    } > "$SRC_DIR/$name.md"
}

@test "render-codex-agents.py: rejects missing args" {
    run python3 "$RENDER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "render-codex-agents.py: renders a basic agent to TOML" {
    write_agent demo sonnet
    run python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ "$status" -eq 0 ]
    [ -f "$OUT_DIR/demo.toml" ]
}

@test "render-codex-agents.py: TOML contains managed header, name, description, model, effort" {
    write_agent demo sonnet
    run python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ "$status" -eq 0 ]
    run cat "$OUT_DIR/demo.toml"
    [[ "$output" == *"# Managed by bin/install-codex.sh from the review-code repo."* ]]
    [[ "$output" == *'name = "demo"'* ]]
    [[ "$output" == *'description = "Test agent demo"'* ]]
    [[ "$output" == *'model = "gpt-5.6-terra"'* ]]
    [[ "$output" == *'model_reasoning_effort = "medium"'* ]]
    [[ "$output" == *"developer_instructions = "* ]]
}

@test "render-codex-agents.py: maps haiku to fast tier (gpt-5.6-luna, low)" {
    write_agent fastone haiku
    run python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ "$status" -eq 0 ]
    run cat "$OUT_DIR/fastone.toml"
    [[ "$output" == *'model = "gpt-5.6-luna"'* ]]
    [[ "$output" == *'model_reasoning_effort = "low"'* ]]
}

@test "render-codex-agents.py: maps opus to deep tier (gpt-5.6-sol, high)" {
    write_agent deepone opus
    run python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ "$status" -eq 0 ]
    run cat "$OUT_DIR/deepone.toml"
    [[ "$output" == *'model = "gpt-5.6-sol"'* ]]
    [[ "$output" == *'model_reasoning_effort = "high"'* ]]
}

@test "render-codex-agents.py: skips nested metadata block when parsing frontmatter" {
    write_agent demo sonnet blue
    run python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ "$status" -eq 0 ]
    # Nested metadata should not leak into TOML keys.
    run grep -c 'execution-tier' "$OUT_DIR/demo.toml"
    [ "$status" -eq 1 ]
}

@test "render-codex-agents.py: strips color from TOML output" {
    write_agent demo sonnet blue
    run python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ "$status" -eq 0 ]
    run grep '^color' "$OUT_DIR/demo.toml"
    [ "$status" -eq 1 ]
}

@test "render-codex-agents.py: errors on unknown model" {
    write_agent badagent nonexistent-model
    run python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown model"* ]]
}

@test "render-codex-agents.py: errors when frontmatter is missing" {
    echo "no frontmatter here" > "$SRC_DIR/broken.md"
    run python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing YAML frontmatter"* ]]
}

@test "render-codex-agents.py: prunes stale managed TOMLs in output dir" {
    write_agent demo sonnet
    # Render once so demo.toml exists.
    python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ -f "$OUT_DIR/demo.toml" ]
    # Plant a stale managed TOML and an unmanaged one.
    printf '# Managed by bin/install-codex.sh from the review-code repo.\nname = "stale"\n' > "$OUT_DIR/stale.toml"
    printf 'name = "user-owned"\n' > "$OUT_DIR/user.toml"
    # Remove the source so demo.toml should also be pruned (it's managed).
    rm "$SRC_DIR/demo.md"
    run python3 "$RENDER" "$SRC_DIR" "$OUT_DIR"
    [ "$status" -eq 0 ]
    [ ! -f "$OUT_DIR/stale.toml" ]
    [ ! -f "$OUT_DIR/demo.toml" ]
    [ -f "$OUT_DIR/user.toml" ]
}

@test "render-codex-agents.py: renders all 13 real agents" {
    run python3 "$RENDER" "$PROJECT_ROOT/agents" "$OUT_DIR"
    [ "$status" -eq 0 ]
    local count
    count=$(find "$OUT_DIR" -name '*.toml' -type f | wc -l | tr -d ' ')
    [ "$count" -eq 13 ]
}

@test "render-codex-agents.py: real agents emit model and effort lines" {
    run python3 "$RENDER" "$PROJECT_ROOT/agents" "$OUT_DIR"
    [ "$status" -eq 0 ]
    local f count_model count_effort
    for f in "$OUT_DIR"/*.toml; do
        count_model=$(grep -c '^model = ' "$f")
        count_effort=$(grep -c '^model_reasoning_effort = ' "$f")
        [ "$count_model" -eq 1 ]
        [ "$count_effort" -eq 1 ]
    done
}
