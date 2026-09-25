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
    python3 "$SCRIPT" --input "$INPUT" --output-dir "$ARTIFACTS" --name "$NAME"
}

seed_outputs() {
    mkdir -p "$ARTIFACTS/investigations" "$ARTIFACTS/findings" "$ARTIFACTS/coverage"
    printf 'previous investigation' > "$ARTIFACTS/investigations/$NAME.md"
    printf 'previous findings' > "$ARTIFACTS/findings/$NAME.md"
    printf '{"previous":true}' > "$ARTIFACTS/coverage/$NAME.json"
}

assert_outputs_unchanged() {
    [ "$(cat "$ARTIFACTS/investigations/$NAME.md")" = 'previous investigation' ]
    [ "$(cat "$ARTIFACTS/findings/$NAME.md")" = 'previous findings' ]
    [ "$(cat "$ARTIFACTS/coverage/$NAME.json")" = '{"previous":true}' ]
}

@test "reviewer report: writes a clean report and returns artifact paths with spaces" {
    run publish_report
    [ "$status" -eq 0 ]

    [ "$(jq -r '.investigation_path' <<< "$output")" = "$ARTIFACTS/investigations/$NAME.md" ]
    [ "$(jq -r '.findings_path' <<< "$output")" = "$ARTIFACTS/findings/$NAME.md" ]
    [ "$(jq -r '.coverage_path' <<< "$output")" = "$ARTIFACTS/coverage/$NAME.json" ]
    [ "$(jq '.files_read_count' <<< "$output")" -eq 2 ]
    [ "$(jq -c '.gaps' <<< "$output")" = '[]' ]
    [ "$(jq '.finding_bytes' <<< "$output")" -eq 0 ]
    [ -f "$ARTIFACTS/findings/$NAME.md" ]
    [ ! -s "$ARTIFACTS/findings/$NAME.md" ]
    jq -j '.investigation' "$INPUT" > "$TEST_DIR/expected.md"
    cmp "$TEST_DIR/expected.md" "$ARTIFACTS/investigations/$NAME.md"
    [ "$(jq -S -c '.coverage' "$INPUT")" = "$(jq -S -c '.' "$ARTIFACTS/coverage/$NAME.json")" ]
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
