#!/usr/bin/env bats
# Tests for skills/review-code/scripts/gate-voice-lint.py

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    GATE="$PROJECT_ROOT/skills/review-code/scripts/gate-voice-lint.py"
}

field() {
    python3 -c "import json,sys; print(json.loads(sys.stdin.read())$1)"
}

# =============================================================================
# Script structure
# =============================================================================

@test "gate-voice-lint: script exists and is executable" {
    [ -f "$GATE" ]
    [ -x "$GATE" ]
}

@test "gate-voice-lint: has python3 shebang" {
    run head -1 "$GATE"
    [[ "$output" == "#!/usr/bin/env python3" ]]
}

@test "gate-voice-lint: loads the linter from its installed sibling path" {
    # The installed copy under ~/.claude is not a git checkout, so resolution
    # must not depend on git rev-parse.
    run grep -c "rev-parse" "$GATE"
    [[ "$output" == "0" ]]
}

# =============================================================================
# Clean and dirty bodies
# =============================================================================

@test "gate-voice-lint: clean bodies produce no warned ids" {
    run "$GATE" - <<'EOF'
[{"id": 1, "description": "`suggestion`: `users.py:67` fetches each profile inside the loop, so 100 users run 101 queries.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['warned']")" == "0" ]]
    [[ "$(echo "$output" | field "['clean']")" == "1" ]]
    [[ "$(echo "$output" | field "['checked']")" == "1" ]]
}

@test "gate-voice-lint: reports the id of a body that trips a rule" {
    run "$GATE" - <<'EOF'
[{"id": 7, "description": "`blocking`: the read is not pinned by any test.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['warned_ids']")" == "[7]" ]]
    [[ "$(echo "$output" | field "['findings'][0]['warnings'][0]['category']")" == "pinning" ]]
}

@test "gate-voice-lint: lints proposed_fix as well as description" {
    run "$GATE" - <<'EOF'
[{"id": 2, "description": "`suggestion`: `users.py:67` runs 101 queries.", "proposed_fix": "Leverage the existing helper."}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['warned_ids']")" == "[2]" ]]
    [[ "$(echo "$output" | field "['findings'][0]['warnings'][0]['field']")" == "proposed_fix" ]]
}

@test "gate-voice-lint: separates clean from warned across a batch" {
    run "$GATE" - <<'EOF'
[{"id": 1, "description": "`blocking`: the cache stays stale for 300 seconds.", "proposed_fix": null},
 {"id": 2, "description": "`nit`: this pins the behavior.", "proposed_fix": null},
 {"id": 3, "description": "`question`: does `flush()` run twice here?", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['checked']")" == "3" ]]
    [[ "$(echo "$output" | field "['clean']")" == "2" ]]
    [[ "$(echo "$output" | field "['warned_ids']")" == "[2]" ]]
}

@test "gate-voice-lint: code blocks in a body do not trip prose rules" {
    run "$GATE" - <<'EOF'
[{"id": 1, "description": "`suggestion`: call the helper instead.\n```python\nleverage_ensure_robust()\n```", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['warned']")" == "0" ]]
}

# =============================================================================
# Payload capping
# =============================================================================

@test "gate-voice-lint: --limit caps warnings per finding and notes the rest" {
    run "$GATE" --limit 2 - <<'EOF'
[{"id": 1, "description": "`blocking`: this pins the behavior.\nIt is not pinned anywhere.\nThe read is pinned by a test.\nNothing pinned elsewhere covers it.\nThe contract isn't pinned.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['findings'][0]['warnings'][-1]['category']")" == "note" ]]
    [[ "$(echo "$output" | field "['findings'][0]['warnings'][-1]['message']")" == *"further warning"* ]]
}

@test "gate-voice-lint: --limit 0 keeps every warning" {
    run "$GATE" --limit 0 - <<'EOF'
[{"id": 1, "description": "`blocking`: this pins the behavior.\nIt is not pinned anywhere.\nThe read is pinned by a test.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    run bash -c "echo '$output' | python3 -c \"import json,sys; d=json.load(sys.stdin); print(any(w['category']=='note' for w in d['findings'][0]['warnings']))\""
    [[ "$output" == "False" ]]
}

# =============================================================================
# Fail-open contract
# =============================================================================

@test "gate-voice-lint: malformed JSON fails open with exit 0 and an error field" {
    run bash -c "printf 'not json at all' | '$GATE' -"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['checked']")" == "0" ]]
    [[ "$(echo "$output" | field "['warned_ids']")" == "[]" ]]
    run bash -c "printf 'not json at all' | '$GATE' - | python3 -c \"import json,sys; print(json.load(sys.stdin)['error'] is not None)\""
    [[ "$output" == "True" ]]
}

@test "gate-voice-lint: a JSON object instead of an array fails open" {
    run bash -c "printf '{\"id\": 1}' | '$GATE' -"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['error']")" == *"must be a JSON array"* ]]
}

@test "gate-voice-lint: an empty array reports nothing to revert" {
    run bash -c "printf '[]' | '$GATE' -"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['checked']")" == "0" ]]
    [[ "$(echo "$output" | field "['error']")" == "None" ]]
}

@test "gate-voice-lint: a missing input file fails open rather than erroring out" {
    run "$GATE" /nonexistent/path/to/rewrites.json
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['error']")" == *"FileNotFoundError"* ]]
}

@test "gate-voice-lint: a null proposed_fix is skipped without failing" {
    run "$GATE" - <<'EOF'
[{"id": 1, "description": "`nit`: rename `x` to `count`.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['error']")" == "None" ]]
    [[ "$(echo "$output" | field "['clean']")" == "1" ]]
}
