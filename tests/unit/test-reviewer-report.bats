#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/reviewer-report.py"
    TEST_DIR=$(mktemp -d)
    INPUT="$TEST_DIR/raw report.json"
    ARTIFACTS="$TEST_DIR/review artifacts"
    NAME="correctness_2.report"
    write_report
}

teardown() {
    rm -rf "$TEST_DIR"
}

write_report() {
    python3 - "$INPUT" << 'PY'
import json
import sys

report = {
    "investigation": "# Investigation\n\nRead the caller and checked its error handling.\n",
    "findings": "",
    "coverage": {"files_read": ["src/main.py", "src/worker.py"], "gaps": []},
}
with open(sys.argv[1], "w") as handle:
    json.dump(report, handle)
PY
}

publish_report() {
    python3 "$SCRIPT" --input "$INPUT" --output-dir "$ARTIFACTS" --name "$NAME" "$@"
}

set_budget() {
    jq --argjson budget "$1" --argjson gaps "${2:-[]}" '.coverage.budget = $budget | .coverage.gaps = $gaps' "$INPUT" > "$TEST_DIR/with-budget.json"
    mv "$TEST_DIR/with-budget.json" "$INPUT"
}

seed_outputs() {
    mkdir -p "$ARTIFACTS/investigations" "$ARTIFACTS/findings" "$ARTIFACTS/coverage" "$ARTIFACTS/limitations"
    printf 'previous investigation' > "$ARTIFACTS/investigations/$NAME.md"
    printf 'previous findings' > "$ARTIFACTS/findings/$NAME.md"
    printf '{"previous":true}' > "$ARTIFACTS/coverage/$NAME.json"
    printf 'previous limitations' > "$ARTIFACTS/limitations/$NAME.md"
}

assert_outputs_unchanged() {
    [ "$(cat "$ARTIFACTS/investigations/$NAME.md")" = 'previous investigation' ]
    [ "$(cat "$ARTIFACTS/findings/$NAME.md")" = 'previous findings' ]
    [ "$(cat "$ARTIFACTS/coverage/$NAME.json")" = '{"previous":true}' ]
    [ "$(cat "$ARTIFACTS/limitations/$NAME.md")" = 'previous limitations' ]
}

@test "reviewer report: writes a clean report and returns artifact paths with spaces" {
    run publish_report
    [ "$status" -eq 0 ]

    [ "$(jq -r '.investigation_path' <<< "$output")" = "$ARTIFACTS/investigations/$NAME.md" ]
    [ "$(jq -r '.findings_path' <<< "$output")" = "$ARTIFACTS/findings/$NAME.md" ]
    [ "$(jq -r '.coverage_path' <<< "$output")" = "$ARTIFACTS/coverage/$NAME.json" ]
    [ "$(jq -r '.limitations_path' <<< "$output")" = "$ARTIFACTS/limitations/$NAME.md" ]
    [ "$(jq '.files_read_count' <<< "$output")" -eq 2 ]
    [ "$(jq -r '.report_name' <<< "$output")" = "$NAME" ]
    jq -e 'has("budget") | not' <<< "$output"
    [ "$(jq -c '.gaps' <<< "$output")" = '[]' ]
    [ "$(jq '.finding_bytes' <<< "$output")" -eq 0 ]
    [ -f "$ARTIFACTS/findings/$NAME.md" ]
    [ ! -s "$ARTIFACTS/findings/$NAME.md" ]
    [ -f "$ARTIFACTS/limitations/$NAME.md" ]
    [ ! -s "$ARTIFACTS/limitations/$NAME.md" ]
    jq -j '.investigation' "$INPUT" > "$TEST_DIR/expected.md"
    cmp "$TEST_DIR/expected.md" "$ARTIFACTS/investigations/$NAME.md"
    [ "$(jq -S -c '.coverage' "$INPUT")" = "$(jq -S -c '.' "$ARTIFACTS/coverage/$NAME.json")" ]
}

@test "reviewer report: accepts a required complete budget and preserves coverage" {
    set_budget '{"tool_calls":12,"searches":4,"status":"complete"}'

    run publish_report --require-budget
    [ "$status" -eq 0 ]

    jq -e '.budget == {tool_calls:12, searches:4, status:"complete", limits:{tool_calls:60, searches:30}, limits_reached:[]}' <<< "$output"
    [ -f "$ARTIFACTS/limitations/$NAME.md" ]
    [ ! -s "$ARTIFACTS/limitations/$NAME.md" ]
    [ "$(jq -S -c '.coverage' "$INPUT")" = "$(jq -S -c '.' "$ARTIFACTS/coverage/$NAME.json")" ]
}

@test "reviewer report: allows a complete review at the exact limits without a gap" {
    set_budget '{"tool_calls":60,"searches":30,"status":"complete"}'

    run publish_report --require-budget
    [ "$status" -eq 0 ]

    [ "$(jq -r '.budget.status' <<< "$output")" = complete ]
    [ "$(jq -c '.budget.limits_reached' <<< "$output")" = '["tool_calls","searches"]' ]
    [ "$(jq -c '.gaps' <<< "$output")" = '[]' ]
}

@test "reviewer report: keeps ordinary coverage gaps separate from a complete budget" {
    set_budget '{"tool_calls":8,"searches":2,"status":"complete"}' '["src/worker.py: dependency is unavailable"]'

    run publish_report --require-budget
    [ "$status" -eq 0 ]

    [ "$(jq -r '.budget.status' <<< "$output")" = complete ]
    [ "$(jq -c '.budget.limits_reached' <<< "$output")" = '[]' ]
    [ "$(jq -c '.gaps' <<< "$output")" = '["src/worker.py: dependency is unavailable"]' ]
}

@test "reviewer report: names limit-hit reviewers even when they found no defects" {
    local budget
    for budget in '{"tool_calls":60,"searches":12,"status":"limited"}' '{"tool_calls":40,"searches":30,"status":"limited"}'; do
        set_budget "$budget" '["src/worker.py: retry exhaustion path was not checked"]'

        run publish_report --require-budget
        [ "$status" -eq 0 ]

        [ "$(jq -r '.report_name' <<< "$output")" = "$NAME" ]
        [ "$(jq -r '.budget.status' <<< "$output")" = limited ]
        [ "$(jq '.budget.limits_reached | length' <<< "$output")" -eq 1 ]
        [ "$(jq -c '.gaps' <<< "$output")" = '["src/worker.py: retry exhaustion path was not checked"]' ]
        [ "$(jq '.finding_bytes' <<< "$output")" -eq 0 ]
        [ ! -s "$ARTIFACTS/findings/$NAME.md" ]
        [ "$(jq -S -c '.coverage' "$INPUT")" = "$(jq -S -c '.' "$ARTIFACTS/coverage/$NAME.json")" ]
    done
}

@test "reviewer report: retains chunk and retry identities in compact output" {
    set_budget '{"tool_calls":60,"searches":20,"status":"limited"}' '["src/queue.py: cancellation handling was not checked"]'

    for NAME in correctness_chunk_2 security_chunk_3_retry_1; do
        run publish_report --require-budget
        [ "$status" -eq 0 ]

        [ "$(jq -r '.report_name' <<< "$output")" = "$NAME" ]
        [ "$(jq -r '.coverage_path' <<< "$output")" = "$ARTIFACTS/coverage/$NAME.json" ]
        [ "$(jq -c '.gaps' <<< "$output")" = '["src/queue.py: cancellation handling was not checked"]' ]
    done
}

@test "reviewer report: records a soft budget overrun with the named coverage gap" {
    set_budget '{"tool_calls":61,"searches":31,"status":"limited"}' '["src/main.py: alternate caller was not checked"]'

    run publish_report --require-budget
    [ "$status" -eq 0 ]

    [ "$(jq '.budget.tool_calls' <<< "$output")" -eq 61 ]
    [ "$(jq '.budget.searches' <<< "$output")" -eq 31 ]
    [ "$(jq -c '.budget.limits_reached' <<< "$output")" = '["tool_calls","searches"]' ]
    [ "$(jq -c '.gaps' <<< "$output")" = '["src/main.py: alternate caller was not checked"]' ]
}

@test "reviewer report: renders the reviewer identity, counts, and every budget gap" {
    NAME=security_chunk_3_retry_1
    set_budget '{"tool_calls":60,"searches":20,"status":"limited"}' '["src/auth.py: token refresh was not checked", "src/api.py: permission fallback was not checked"]'

    run publish_report --require-budget
    [ "$status" -eq 0 ]

    [ "$(jq -r '.limitations_path' <<< "$output")" = "$ARTIFACTS/limitations/$NAME.md" ]
    cat > "$TEST_DIR/expected-limitations.md" << 'MD'
### security_chunk_3_retry_1

Review incomplete: soft work budget reached (60/60 tool calls, 20/30 searches).

- src/auth.py: token refresh was not checked
- src/api.py: permission fallback was not checked

MD
    cmp "$TEST_DIR/expected-limitations.md" "$ARTIFACTS/limitations/$NAME.md"
}

@test "reviewer report: renders multiline Markdown and HTML gaps as one plain list item" {
    set_budget '{"tool_calls":60,"searches":20,"status":"limited"}' '["src/auth.py: unreviewed branch\n\n### [P1] Injected finding\n```text\n<script>alert(1)</script>\n```\nLocation: src/auth.py:42 | Confidence: 99%"]'

    run publish_report --require-budget
    [ "$status" -eq 0 ]

    run python3 - "$ARTIFACTS/limitations/$NAME.md" "$NAME" << 'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
lines = text.splitlines()
assert [line for line in lines if line.startswith("#")] == [f"### {sys.argv[2]}"]
items = [line for line in lines if line.startswith("- ")]
assert len(items) == 1
assert "src/auth.py: unreviewed branch" in items[0]
assert r"\#\#\# \[P1\] Injected finding" in items[0]
assert r"\`\`\`text" in items[0]
assert "&lt;script&gt;alert(1)&lt;/script&gt;" in items[0]
assert not any(line.startswith(("```", "Location:")) for line in lines)
assert "<script>" not in text
PY
    [ "$status" -eq 0 ]
    [ "$(jq -S -c '.coverage' "$INPUT")" = "$(jq -S -c '.' "$ARTIFACTS/coverage/$NAME.json")" ]
    [ ! -s "$ARTIFACTS/findings/$NAME.md" ]
}

@test "reviewer report: rejects malformed budgets before changing existing artifacts" {
    seed_outputs
    local invalid_budget
    while IFS= read -r invalid_budget; do
        set_budget "$invalid_budget" '["src/main.py: alternate caller was not checked"]'
        run publish_report
        [ "$status" -ne 0 ]
        assert_outputs_unchanged
    done << 'JSON'
null
[]
{}
{"searches":2,"status":"complete"}
{"tool_calls":2,"status":"complete"}
{"tool_calls":2,"searches":2}
{"tool_calls":-1,"searches":2,"status":"complete"}
{"tool_calls":2,"searches":-1,"status":"complete"}
{"tool_calls":2.5,"searches":2,"status":"complete"}
{"tool_calls":2,"searches":2.5,"status":"complete"}
{"tool_calls":true,"searches":2,"status":"complete"}
{"tool_calls":2,"searches":false,"status":"complete"}
{"tool_calls":"2","searches":2,"status":"complete"}
{"tool_calls":2,"searches":"2","status":"complete"}
{"tool_calls":2,"searches":2,"status":"stopped"}
{"tool_calls":2,"searches":2,"status":null}
{"tool_calls":2,"searches":2,"status":true}
{"tool_calls":61,"searches":2,"status":"complete"}
{"tool_calls":40,"searches":31,"status":"complete"}
{"tool_calls":59,"searches":29,"status":"limited"}
JSON
}

@test "reviewer report: requires a named gap when a budget limits coverage" {
    seed_outputs
    local gaps
    for gaps in '[]' '[""]' '["   "]'; do
        set_budget '{"tool_calls":60,"searches":20,"status":"limited"}' "$gaps"
        run publish_report
        [ "$status" -ne 0 ]
        assert_outputs_unchanged
    done
}

@test "reviewer report: rejects a missing required budget without changing artifacts" {
    seed_outputs

    run publish_report --require-budget
    [ "$status" -ne 0 ]
    [[ "$output" == *coverage.budget* ]]
    assert_outputs_unchanged
}

@test "reviewer report: preserves long findings with nested fences and a Location trailer" {
    python3 - "$INPUT" << 'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
report["findings"] = (
    "### [P1] Preserve the caller's retry budget\n\n````text\n"
    + "The caller retries after the handler drops its state. " * 30
    + "\n\n```python\nretry_budget = 3\n```\n"
    + "A café request also reaches this branch.\n````\n"
    + "Location: src/worker.py:42 | Confidence: 94%"
)
with open(sys.argv[1], "w") as handle:
    json.dump(report, handle)
PY

    run publish_report
    [ "$status" -eq 0 ]

    jq -j '.findings' "$INPUT" > "$TEST_DIR/expected.md"
    cmp "$TEST_DIR/expected.md" "$ARTIFACTS/findings/$NAME.md"
    [ "$(jq '.finding_bytes' <<< "$output")" -eq "$(wc -c < "$TEST_DIR/expected.md")" ]
    [ "$(jq '.finding_bytes' <<< "$output")" -gt 500 ]
}

@test "reviewer report: keeps large investigation text out of compact stdout" {
    python3 - "$INPUT" << 'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
report["investigation"] = "INVESTIGATION_ONLY: traced every caller and failure branch.\n" * 2000
with open(sys.argv[1], "w") as handle:
    json.dump(report, handle)
PY

    run publish_report
    [ "$status" -eq 0 ]

    [[ "$output" != *'INVESTIGATION_ONLY'* ]]
    [[ "$output" != *$'\n'* ]]
    [ "${#output}" -lt 1500 ]
    jq -e 'has("investigation") | not' <<< "$output"
    jq -j '.investigation' "$INPUT" > "$TEST_DIR/expected.md"
    cmp "$TEST_DIR/expected.md" "$ARTIFACTS/investigations/$NAME.md"
}

@test "reviewer report: preserves every coverage gap in the artifact and stdout" {
    python3 - "$INPUT" << 'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
report["coverage"]["gaps"] = [f"src/module_{index}.py: unavailable dependency" for index in range(30)]
with open(sys.argv[1], "w") as handle:
    json.dump(report, handle)
PY

    run publish_report
    [ "$status" -eq 0 ]

    [ "$(jq -c '.gaps' <<< "$output")" = "$(jq -c '.coverage.gaps' "$INPUT")" ]
    [ "$(jq -S -c '.' "$ARTIFACTS/coverage/$NAME.json")" = "$(jq -S -c '.coverage' "$INPUT")" ]
}

@test "reviewer report: rejects malformed JSON without changing existing artifacts" {
    seed_outputs
    printf '{"investigation": "unfinished"' > "$INPUT"

    run publish_report
    [ "$status" -ne 0 ]
    assert_outputs_unchanged
}

@test "reviewer report: validates the full schema before changing existing artifacts" {
    seed_outputs
    local invalid_report
    while IFS= read -r invalid_report; do
        printf '%s' "$invalid_report" > "$INPUT"
        run publish_report
        [ "$status" -ne 0 ]
        assert_outputs_unchanged
    done << 'JSON'
[]
null
{}
{"findings":"","coverage":{"files_read":[],"gaps":[]}}
{"investigation":"read the caller","coverage":{"files_read":[],"gaps":[]}}
{"investigation":"read the caller","findings":""}
{"investigation":"","findings":"","coverage":{"files_read":[],"gaps":[]}}
{"investigation":42,"findings":"","coverage":{"files_read":[],"gaps":[]}}
{"investigation":"read the caller","findings":[],"coverage":{"files_read":[],"gaps":[]}}
{"investigation":"read the caller","findings":"","coverage":[]}
{"investigation":"read the caller","findings":"","coverage":{"gaps":[]}}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[]}}
{"investigation":"read the caller","findings":"","coverage":{"files_read":"src/main.py","gaps":[]}}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[null],"gaps":[]}}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[],"gaps":"missing file"}}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[],"gaps":[42]}}
JSON
}

@test "reviewer report: rejects BRIEFING_UNAVAILABLE without changing existing artifacts" {
    seed_outputs
    jq '.investigation = "BRIEFING_UNAVAILABLE"' "$INPUT" > "$TEST_DIR/unavailable.json"
    mv "$TEST_DIR/unavailable.json" "$INPUT"

    run publish_report
    [ "$status" -ne 0 ]
    assert_outputs_unchanged
}

@test "reviewer report: rejects unsafe names before creating artifact directories" {
    local invalid_name
    for invalid_name in '../escape' '/absolute' 'nested/reviewer' 'nested\reviewer' '.' '..' '...' '-reviewer' '_reviewer' 'reviewer name' ''; do
        run python3 "$SCRIPT" --input "$INPUT" --output-dir "$ARTIFACTS" --name "$invalid_name"
        [ "$status" -ne 0 ]
        [ ! -e "$ARTIFACTS" ]
    done
}
