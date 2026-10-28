#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    EVAL="$PROJECT_ROOT/evals/scripts/run-comment-quality-eval.py"
    OUT="$BATS_TEST_TMPDIR/run"
    DIFF="$BATS_TEST_TMPDIR/diff.patch"
    printf '%s\n' 'diff --git a/x b/x' > "$DIFF"
    STUB_LOG="$BATS_TEST_TMPDIR/claude-calls.jsonl"
    export STUB_LOG
    : > "$STUB_LOG"
    export CLAUDE_BIN="$BATS_TEST_TMPDIR/claude"
    cat > "$CLAUDE_BIN" << 'PY'
#!/usr/bin/env python3
"""Answer `claude -p` calls from the eval with canned replies, chosen by stage.

STUB_REWRITE names gate stages and ids to reject, as "stage:id,stage:id".
STUB_TRIM marks those rejections trim-only, in the same form.
STUB_COMPOSE_ERROR names composer stages and ids to fail with an item error, in the same form.
STUB_DIRTY names composer stages and ids whose body gets a negative-subject sentence, in the same form.
STUB_FAIL makes every call exit 1.
"""
import json
import os
import re
import sys

args = sys.argv[1:]
prompt = args[args.index("-p") + 1]
input_path = re.search(r'JSON input at "([^"]+)"', prompt).group(1)
stage = os.path.basename(input_path).removesuffix("-input.json")
items = json.load(open(input_path))
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps({
        "stage": stage,
        "model": args[args.index("--model") + 1],
        "system": args[args.index("--system-prompt") + 1],
    }) + "\n")
if os.environ.get("STUB_FAIL"):
    sys.exit(1)


def pairs(name):
    return {tuple(pair.split(":")) for pair in os.environ.get(name, "").split(",") if pair}


family = "comprehension-recheck" if stage.startswith("comprehension-recheck") else stage
if stage.startswith(("comment-compose", "comment-repair", "lint-repair")):
    errors = pairs("STUB_COMPOSE_ERROR")
    result = [
        {"id": item["id"], "description": None, "proposed_fix": item["proposed_fix"], "unchanged": False, "error": "Stub error."}
        if (stage, str(item["id"])) in errors
        else {
            "id": item["id"],
            "description": f"`{item['severity']}`: Composed body {item['id']}."
            + (" No test covers it." if (stage, str(item["id"])) in pairs("STUB_DIRTY") else ""),
            "proposed_fix": item["proposed_fix"],
            "unchanged": False,
            "error": None,
        }
        for item in items
    ]
else:
    result = []
    for item in items:
        key = (family, str(item["id"]))
        rewrite = key in pairs("STUB_REWRITE")
        result.append({
            "id": item["id"],
            "coverage": {
                field: True
                for field in ("problem", "trigger", "mechanism", "result", "requested_change", "regression_case")
            },
            "inference_required": False,
            "unresolved": [{"phrase": "this", "stands_for": "unclear"}] if rewrite and key not in pairs("STUB_TRIM") else [],
            "verdict": "REWRITE" if rewrite else "PASS",
            "notes": "Cut the walkthrough." if rewrite else "",
            "trim_only": key in pairs("STUB_TRIM"),
        })
print(json.dumps({"result": "````json\n" + json.dumps(result) + "\n````", "total_cost_usd": 0.01}))
PY
    chmod +x "$CLAUDE_BIN"
}

run_eval() {
    run python3 "$EVAL" --diff "$DIFF" --out "$OUT" "$@"
}

summary() {
    jq "$@" "$OUT/summary.json"
}

stages() {
    jq -sc 'map(.stage)' "$STUB_LOG"
}

draft() {
    jq -r ".cases[$1].draft" "$PROJECT_ROOT/tests/fixtures/finding-comments/pr-113272.json"
}

agent_body() {
    awk 'n == 2 {print} /^---$/ {n++}' | sed '/./,$!d'
}

@test "comment quality eval: preflight passes publish the reviewer drafts, and only bodies with a non-length lint warning get a composer repair" {
    run_eval

    [ "$status" -eq 0 ]
    [ "$(summary .published)" -eq 12 ]
    [ "$(summary .before_words)" -eq 1034 ]
    [ "$(summary .after_words)" -eq 311 ]
    [ "$(jq -c '[.[].id]' "$OUT/lint-repair-input.json")" = '[3,4,5,6,10,12]' ]
    jq -e '.[0].reasons | length > 0 and all(.[]; type == "string")' "$OUT/lint-repair-input.json"
    [ "$(summary -r '.cases[2].body')" = '`suggestion`: Composed body 3.' ]
    [ "$(summary -r '.cases[0].body')" = "$(draft 0)" ]
    stages | jq -e 'index("finding-preflight") == 0 and index("lint-repair") == 1 and index("comprehension") == 2 and all(.[]; startswith("comment-") | not)'
}

@test "comment quality eval: a preflight rewrite publishes the composer's body" {
    STUB_REWRITE="finding-preflight:1" run_eval

    [ "$status" -eq 0 ]
    [ "$(summary .published)" -eq 12 ]
    [ "$(summary -r '.cases[0].body')" = '`suggestion`: Composed body 1.' ]
    [ "$(summary '.cases[0].words')" -eq 4 ]
    [ "$(summary -c '.cases[0].lint')" = '[]' ]
    stages | jq -e 'index("comment-compose") == 1 and index("comprehension") > 1'
}

@test "comment quality eval: a final-gate rewrite gets one repair from the contract's reasons, and a second rewrite withholds it" {
    STUB_REWRITE="comprehension:2,comprehension-recheck:2,comprehension:3" run_eval

    [ "$status" -eq 0 ]
    [ "$(summary .published)" -eq 11 ]
    [ "$(summary -r '.cases[1].withheld')" = "rewrite_failed" ]
    [ "$(summary '.cases[1].lint')" = "null" ]
    [ "$(summary -r '.cases[2].body')" = '`suggestion`: Composed body 3.' ]
    jq -e '.[0].reasons | index("Cut the walkthrough.")' "$OUT/comment-repair-2-input.json"
    [ "$(jq -c '.[0].unresolved' "$OUT/comment-repair-2-input.json")" = '[{"phrase":"this","stands_for":"unclear"}]' ]
    [ "$(jq -c '.[0] | has("coverage")' "$OUT/comment-repair-2-input.json")" = "false" ]
}

@test "comment quality eval: a trim-only rewrite on the recheck publishes instead of withholding" {
    STUB_REWRITE="comprehension:2,comprehension-recheck:2" STUB_TRIM="comprehension-recheck:2" run_eval

    [ "$status" -eq 0 ]
    [ "$(summary .published)" -eq 12 ]
    [ "$(summary -r '.cases[1].body')" = '`suggestion`: Composed body 2.' ]
}

@test "comment quality eval: a blocking finding the recheck rejects gets a two-sentence repair and publishes" {
    STUB_REWRITE="comprehension:1,comprehension-recheck:1" run_eval \
        --fixture "$PROJECT_ROOT/tests/fixtures/finding-comments/pr-121510.json"

    [ "$status" -eq 0 ]
    [ "$(summary .published)" -eq 7 ]
    [ "$(summary .published_over_gate)" -eq 1 ]
    [ "$(jq -r '.[0].two_sentence_limit' "$OUT/comment-repair-blocking-1-input.json")" = "true" ]
    stages | jq -e 'index("comprehension-recheck-blocking-1") > index("comment-repair-blocking-1")'
}

@test "comment quality eval: a failed lint repair keeps the body it replaced" {
    STUB_COMPOSE_ERROR="lint-repair:3" run_eval

    [ "$status" -eq 0 ]
    [ "$(summary .published)" -eq 12 ]
    [ "$(summary -r '.cases[2].body')" = "$(draft 2)" ]
    [ "$(summary -r '.cases[3].body')" = '`suggestion`: Composed body 4.' ]
}

@test "comment quality eval: a composed body with a lint warning goes to the lint repair, and a clean one does not" {
    STUB_REWRITE="finding-preflight:1,finding-preflight:2" STUB_DIRTY="comment-compose:2" run_eval

    [ "$status" -eq 0 ]
    [ "$(jq -c 'map(.id) | (index(1) == null) and (index(2) != null)' "$OUT/lint-repair-input.json")" = "true" ]
    [ "$(summary -r '.cases[0].body')" = '`suggestion`: Composed body 1.' ]
    [ "$(summary -r '.cases[1].body')" = '`suggestion`: Composed body 2.' ]
}

@test "comment quality eval: a failed call withholds every finding instead of passing it" {
    STUB_FAIL=1 run_eval

    [ "$status" -eq 0 ]
    [ "$(summary .published)" -eq 0 ]
    [ "$(summary -r '[.cases[].withheld] | unique | join(",")')" = "gate_error" ]
}

@test "comment quality eval: --ref reads agent definitions, models, and the briefing from that commit" {
    local base=2bf4e2c
    run_eval --ref "$base"

    [ "$status" -eq 0 ]
    [ "$(jq -sr '.[0].system' "$STUB_LOG")" = "$(git -C "$PROJECT_ROOT" show "$base:agents/comprehension-gate.md" | agent_body)" ]
    [ "$(jq -sr '.[0].system' "$STUB_LOG")" != "$(agent_body < "$PROJECT_ROOT/agents/comprehension-gate.md")" ]
    [ "$(jq -sr '.[0].model' "$STUB_LOG")" = "haiku" ]
    grep -q "usually two to four sentences" "$OUT/briefing.md"
    [ "$(summary -r .commit)" = "$(git -C "$PROJECT_ROOT" rev-parse "$base")" ]
}

@test "comment quality eval: --style sets the comment style of every finding" {
    run_eval --style detailed

    [ "$status" -eq 0 ]
    [ "$(jq -r '[.[].comment_style] | unique | join(",")' "$OUT/finding-preflight-input.json")" = "detailed" ]
}

@test "comment quality eval: a fixture without posted or approved bodies still scores" {
    local fixture="$PROJECT_ROOT/tests/fixtures/finding-comments/pr-121510.json"
    run_eval --fixture "$fixture"

    [ "$status" -eq 0 ]
    [ "$(summary .published)" -eq 7 ]
    [ "$(summary .after_words)" = "null" ]
    [ "$(summary '.cases[2].before_words')" = "null" ]
    [ "$(summary .before_words)" -eq "$(jq -r '[.cases[].before | select(. != null)] | join(" ")' "$fixture" | wc -w)" ]
    [[ "$output" == *'| 3 | `posthog/api/cohort.py:1792` | - | - |'* ]]
}

@test "comment quality eval: the summary lists the voice lint categories each published body still carries" {
    local fixture="$PROJECT_ROOT/tests/fixtures/finding-comments/pr-118814.json"
    # Every stub gate passes and the lint repair fails, so each draft publishes with its "legacy" names sentence.
    STUB_COMPOSE_ERROR="lint-repair:1,lint-repair:2" run_eval --fixture "$fixture"

    [ "$status" -eq 0 ]
    [ "$(summary .published)" -eq 2 ]
    [ "$(summary -c '.cases[0].lint')" = '["action_subject","negative_subject"]' ]
    [ "$(summary -c '.cases[1].lint')" = '["action_subject"]' ]
    [[ "$output" == *'| action_subject, negative_subject |'* ]]
}

@test "comment quality eval: word counts leave out fenced code, and replies parse with mismatched fences or leading prose" {
    run python3 - "$EVAL" << 'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("evaluation", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
body = "`nit`: Use the shared list:\n\n````ts\nconst a = 1\n```\nnested\n```\n````\n\nThen drop it."
assert module.words(body) == 17, module.words(body)
assert module.prose_words(body) == 8, module.prose_words(body)
assert module.prose_words("Wrap it:\n\n  ~~~tsx\n  <div />\n  ~~~\n") == 2
assert module.parse_array('````json\n[{"id": 1}]\n```') == [{"id": 1}]
assert module.parse_array('[{"id": 2}]') == [{"id": 2}]
assert module.parse_array('I could not write the file.\n\n```json\n[{"id": 3}]\n```') == [{"id": 3}]
assert module.parse_array('```json\n[{"id": 4}]\n```\n\nRewritten:\n\n```text\nx\n```') == [{"id": 4}]
assert module.parse_array('```json\n[{"id": 5}]\n```\n```') == [{"id": 5}]
PY
    [ "$status" -eq 0 ]
}

@test "comment quality eval: an existing output directory is refused" {
    mkdir -p "$OUT"

    run_eval

    [ "$status" -ne 0 ]
    [ ! -s "$STUB_LOG" ]
}
