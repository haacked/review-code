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
    "open_from_others": [],
}
with open(sys.argv[1], "w") as handle:
    json.dump(report, handle)
PY
}

publish_report() {
    python3 "$SCRIPT" --input "$INPUT" --output-dir "$ARTIFACTS" --name "$NAME"
}

seed_outputs() {
    mkdir -p "$ARTIFACTS/investigations" "$ARTIFACTS/findings" "$ARTIFACTS/coverage" "$ARTIFACTS/open-from-others"
    printf 'previous investigation' > "$ARTIFACTS/investigations/$NAME.md"
    printf 'previous findings' > "$ARTIFACTS/findings/$NAME.md"
    printf '{"previous":true}' > "$ARTIFACTS/coverage/$NAME.json"
    printf '[{"previous":true}]' > "$ARTIFACTS/open-from-others/$NAME.json"
}

assert_outputs_unchanged() {
    [ "$(cat "$ARTIFACTS/investigations/$NAME.md")" = 'previous investigation' ]
    [ "$(cat "$ARTIFACTS/findings/$NAME.md")" = 'previous findings' ]
    [ "$(cat "$ARTIFACTS/coverage/$NAME.json")" = '{"previous":true}' ]
    [ "$(cat "$ARTIFACTS/open-from-others/$NAME.json")" = '[{"previous":true}]' ]
}

valid_open_entry() {
    jq -n '{
        location: "posthog/deletion.py:88",
        raised_by: "@frank",
        link: "https://github.com/org/repo/pull/1#discussion_r1",
        problem: "Deleting by person_id misses rows in the materialized column at posthog/deletion.py:88.",
        assessment: "valid",
        severity: "blocking",
        why_not_reraised: "@frank'"'"'s thread is open."
    }'
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
    [ "$(jq '.open_from_others_count' <<< "$output")" -eq 0 ]
    [ "$(jq -c '.' "$ARTIFACTS/open-from-others/$NAME.json")" = '[]' ]
}

@test "reviewer report: writes open problems from other reviewers to an artifact and only counts them on stdout" {
    jq --argjson first "$(valid_open_entry | jq '.problem = "OPEN_PROBLEM_ONLY: rows survive the delete at posthog/deletion.py:88."')" '
        .open_from_others = [
            $first,
            {
                location: "PR",
                raised_by: "@alice",
                link: "http://ghe.example.com/org/repo/pull/7",
                problem: "OPEN_PROBLEM_ONLY: the migration at posthog/migrations/0042.py:12 has no rollback.",
                assessment: "unsure",
                severity: "question",
                why_not_reraised: "The review summary already asks for a rollback plan."
            }
        ]' "$INPUT" > "$TEST_DIR/with-open.json"
    mv "$TEST_DIR/with-open.json" "$INPUT"

    run publish_report
    [ "$status" -eq 0 ]

    [ "$(jq '.open_from_others_count' <<< "$output")" -eq 2 ]
    [ "$(jq -S -c '.open_from_others' "$INPUT")" = "$(jq -S -c '.' "$ARTIFACTS/open-from-others/$NAME.json")" ]
    [[ "$output" != *'OPEN_PROBLEM_ONLY'* ]]
    jq -e 'has("open_from_others") | not' <<< "$output"
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
    local invalid_report invalid_entry
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
{"investigation":"read the caller","findings":"","coverage":{"files_read":[],"gaps":[]}}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[],"gaps":[]},"open_from_others":null}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[],"gaps":[]},"open_from_others":{}}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[],"gaps":[]},"open_from_others":"none"}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[],"gaps":[]},"open_from_others":[42]}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[],"gaps":[]},"open_from_others":["posthog/deletion.py:88"]}
{"investigation":"read the caller","findings":"","coverage":{"files_read":[],"gaps":[]},"open_from_others":[null]}
JSON

    local valid key
    valid=$(valid_open_entry)
    while IFS= read -r invalid_entry; do
        jq -n --argjson valid "$valid" --argjson entry "$invalid_entry" \
            '{investigation: "read the caller", findings: "", coverage: {files_read: [], gaps: []}, open_from_others: [$valid, ($valid + $entry)]}' > "$INPUT"
        run publish_report
        [ "$status" -ne 0 ]
        assert_outputs_unchanged
    done << 'JSON'
{"location":88}
{"assessment":"maybe"}
{"assessment":"Valid"}
{"severity":"critical"}
{"severity":"Blocking"}
{"link":"discussion_r1"}
{"link":"github.com/org/repo/pull/1"}
{"link":"ftp://github.com/org/repo/pull/1"}
{"link":"javascript:alert(1)"}
JSON

    for key in location raised_by link problem assessment severity why_not_reraised; do
        jq -n --argjson valid "$valid" --arg key "$key" \
            '{investigation: "read the caller", findings: "", coverage: {files_read: [], gaps: []}, open_from_others: [$valid, ($valid | del(.[$key]))]}' > "$INPUT"
        run publish_report
        [ "$status" -ne 0 ]
        [[ "$output" == *"$key"* ]]
        assert_outputs_unchanged

        jq -n --argjson valid "$valid" --arg key "$key" \
            '{investigation: "read the caller", findings: "", coverage: {files_read: [], gaps: []}, open_from_others: [$valid, ($valid | .[$key] = "")]}' > "$INPUT"
        run publish_report
        [ "$status" -ne 0 ]
        [[ "$output" == *"$key"* ]]
        assert_outputs_unchanged
    done
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
