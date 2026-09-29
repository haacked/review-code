#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    REPLAY="$PROJECT_ROOT/evals/scripts/replay-editor-eval.py"
    SOURCE="$PROJECT_ROOT/evals/editor-pass/fixtures.json"
    FIXTURES="$BATS_TEST_TMPDIR/fixtures.json"
    RESULT="$BATS_TEST_TMPDIR/replay.json"
}

mutate_fixture() {
    python3 - "$SOURCE" "$FIXTURES" "$1" << 'PY'
import json
from pathlib import Path
import sys

source, destination, mode = sys.argv[1:]
fixture = json.loads(Path(source).read_text())
if mode == "wrong_expectation":
    case = next(case for case in fixture["cases"] if case["id"] == "valid_neighbor")
    case["expected"] = {"published_ids": [1], "withheld_ids": [2]}
elif mode == "invalid_root":
    fixture = []
elif mode == "invalid_case":
    fixture["cases"] = [None]
elif mode == "nonboolean_recovery":
    case = next(case for case in fixture["cases"] if case["id"] == "unchanged_fix_contamination")
    case["recover_identical_body"] = "false"
else:
    raise AssertionError(mode)
Path(destination).write_text(json.dumps(fixture) + "\n")
PY
}

@test "editor eval replay: handwritten cases reproduce the expected publication safeguards and self-approval limitation" {
    run python3 "$REPLAY"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$RESULT"

    run python3 - "$RESULT" << 'PY'
import json
from pathlib import Path
import sys

result = json.loads(Path(sys.argv[1]).read_text())
expected_ids = {
    "valid_neighbor", "lost_claim", "shortened_citation", "rejected_edit_verdict",
    "unchanged_fix_contamination", "identical_body_recovery", "incomplete_causal_explanation",
    "rewrite_after_completed_edit", "missing_verdict", "nonboolean_coverage",
    "duplicate_candidate", "missing_candidate", "self_approval_without_cold_read",
}
both_publish = {"valid_neighbor", "identical_body_recovery", "self_approval_without_cold_read"}
assert result["all_expected"] is True
assert len(result["cases"]) == len(expected_ids)
assert {case["id"] for case in result["cases"]} == expected_ids
for case in result["cases"]:
    assert case["matches_expected"] is True, case
    assert sorted(case["published_ids"]) == ([1, 2] if case["id"] in both_publish else [1]), case
    assert case["withheld_ids"] == ([] if case["id"] in both_publish else [2]), case
PY
    [ "$status" -eq 0 ]
}

@test "editor eval replay: accepts an explicit fixture path" {
    cp "$SOURCE" "$FIXTURES"
    run python3 "$REPLAY" --fixtures "$FIXTURES"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$RESULT"
    jq -e '.all_expected == true and (.cases | length) == 13' "$RESULT"
}

@test "editor eval replay: incorrect expectations do not change actual publication or pass the case" {
    mutate_fixture wrong_expectation
    run python3 "$REPLAY" --fixtures "$FIXTURES"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" > "$RESULT"

    jq -e '
        .all_expected == false
        and ([.cases[] | select(.id == "valid_neighbor")] | length) == 1
        and (.cases[] | select(.id == "valid_neighbor")
            | .matches_expected == false and .published_ids == [1,2] and .withheld_ids == [])
    ' "$RESULT"
}

@test "editor eval replay: malformed fixture objects and nonboolean recovery flags are invalid" {
    for mutation in invalid_root invalid_case nonboolean_recovery; do
        mutate_fixture "$mutation"
        run python3 "$REPLAY" --fixtures "$FIXTURES"
        [ "$status" -ne 0 ]
    done
}
