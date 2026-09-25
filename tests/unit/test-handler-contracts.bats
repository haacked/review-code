#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SKILL="$PROJECT_ROOT/skills/review-code"
    ARTIFACTS="$BATS_TEST_TMPDIR/artifacts with spaces"
    mkdir -p "$ARTIFACTS"
}

extract_documented_block() {
    python3 - "$1" "$2" "$3" "$SKILL" "$ARTIFACTS" << 'PY'
import re
import sys
from pathlib import Path

document, language, needle, skill, artifacts = sys.argv[1:]
blocks = re.findall(r"^(`{3,4})" + language + r"\n(.*?)^\1$", Path(document).read_text(), re.M | re.S)
matches = [body for _, body in blocks if needle in body]
assert len(matches) == 1, f"expected one {language} block containing {needle!r}, found {len(matches)}"
print(matches[0].replace("~/.agents/skills/review-code", skill).replace("<artifacts_dir>", artifacts), end="")
PY
}

@test "handler contracts: documented reviewer report command separates evidence from findings" {
    report_path="$ARTIFACTS/report.json"
    report_name="correctness"
    jq -n '{investigation: "Full investigation", findings: "Complete findings", coverage: {files_read: ["src/example.py"], gaps: []}}' > "$report_path"
    extract_documented_block "$SKILL/handlers/reviewer-output.md" bash reviewer-report.py > "$ARTIFACTS/report.sh"

    run env report_path="$report_path" report_name="$report_name" bash -e "$ARTIFACTS/report.sh"

    [ "$status" -eq 0 ]
    [ "$(cat "$ARTIFACTS/findings/correctness.md")" = "Complete findings" ]
    [ "$(cat "$ARTIFACTS/investigations/correctness.md")" = "Full investigation" ]
    [[ "$output" != *"Full investigation"* ]]
}

@test "handler contracts: reviewer dispatch registers its expected report" {
    report_path="$ARTIFACTS/reports/security.json"
    extract_documented_block "$SKILL/handlers/reviewer-output.md" bash expected-reviewer-reports.txt > "$ARTIFACTS/register.sh"

    run env report_path="$report_path" bash -e "$ARTIFACTS/register.sh"

    [ "$status" -eq 0 ]
    run env report_path="$report_path" bash -e "$ARTIFACTS/register.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$ARTIFACTS/expected-reviewer-reports.txt")" = "$report_path" ]
    [ "$(wc -l < "$ARTIFACTS/expected-reviewer-reports.txt")" -eq 1 ]
}

@test "handler contracts: full append advances existing metadata through the shared writer" {
    review_file="$ARTIFACTS/review.md"
    cat > "$review_file" << 'EOF'
<!-- review-metadata
review_commit: old-head
reviewed_at: 2026-01-01T00:00:00Z
review_mode: delta
delta_from: older-head
custom: keep
-->
# Earlier findings

# Appended full review
EOF
    extract_documented_block "$SKILL/handlers/review-compose.md" bash metadata_args > "$ARTIFACTS/metadata.sh"

    run env review_file="$review_file" review_commit=new-head bash -e "$ARTIFACTS/metadata.sh"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^<!-- review-metadata$' "$review_file")" -eq 1 ]
    grep -Fxq 'review_commit: new-head' "$review_file"
    grep -Fxq 'review_mode: full' "$review_file"
    grep -Fxq 'custom: keep' "$review_file"
    grep -Fxq '# Earlier findings' "$review_file"
    grep -Fxq '# Appended full review' "$review_file"
    ! grep -q '^delta_from:' "$review_file"
}

@test "handler contracts: retained reviewer evidence survives session cleanup" {
    review_file="$BATS_TEST_TMPDIR/saved review.md"
    mkdir -p "$ARTIFACTS/reports"
    jq -n '{investigation: "Evidence", findings: "Finding", coverage: {files_read: ["a.py"], gaps: ["Cannot verify b.py"]}}' > "$ARTIFACTS/reports/security.json"
    printf '%s\n' "$ARTIFACTS/reports/security.json" > "$ARTIFACTS/expected-reviewer-reports.txt"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash reviewer-report.py \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/retain.sh"

    run env review_file="$review_file" bash -e "$ARTIFACTS/retain.sh"

    [ "$status" -eq 0 ]
    rm -rf "$ARTIFACTS"
    [ "$(cat "${review_file}.artifacts/session-123/investigations/security.md")" = "Evidence" ]
    jq -e '.gaps == ["Cannot verify b.py"]' "${review_file}.artifacts/session-123/coverage/security.json"
}

@test "handler contracts: retention fails when no reports were registered" {
    review_file="$BATS_TEST_TMPDIR/saved review.md"
    mkdir -p "$ARTIFACTS/reports"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash reviewer-report.py \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/retain.sh"

    run env review_file="$review_file" bash -e "$ARTIFACTS/retain.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"reviewer report"* ]]
}

@test "handler contracts: retention fails when any expected report is missing" {
    review_file="$BATS_TEST_TMPDIR/saved review.md"
    mkdir -p "$ARTIFACTS/reports"
    jq -n '{investigation: "Evidence", findings: "Finding", coverage: {files_read: ["a.py"], gaps: []}}' > "$ARTIFACTS/reports/security.json"
    printf '%s\n' "$ARTIFACTS/reports/security.json" "$ARTIFACTS/reports/correctness.json" > "$ARTIFACTS/expected-reviewer-reports.txt"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash reviewer-report.py \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/retain.sh"

    run env review_file="$review_file" bash -e "$ARTIFACTS/retain.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"correctness.json"* ]]
}

@test "handler contracts: documented voice lint command projects the findings array" {
    jq -n '{
        findings: [
            {id: 1, severity: "blocking", description: "`blocking`: The cache stays stale for 300 seconds.", proposed_fix: null},
            {id: 2, severity: "nit", description: "`nit`: This pins the behavior.", proposed_fix: null}
        ],
        rewrites_needed: [],
        withheld: [{id: 3, description: "`nit`: This pins the behavior."}]
    }' > "$ARTIFACTS/finding-quality-voiced.json"
    extract_documented_block "$SKILL/handlers/review-finding-quality.md" bash voice-lint-input.json > "$ARTIFACTS/voice.sh"

    run bash -e "$ARTIFACTS/voice.sh"

    [ "$status" -eq 0 ]
    jq -e 'type == "array" and length == 2 and all(.[]; keys == ["description", "id", "proposed_fix"])' "$ARTIFACTS/voice-lint-input.json"
    jq -e '.error == null and .checked == 2 and .clean == 1 and .warned_ids == [2]' "$ARTIFACTS/voice-lint-result.json"
}

@test "handler contracts: documented draft command wraps publication and preserves selected bodies" {
    jq -n '{
        findings: [],
        comments: [
            {path: "src/skip.py", line: 10, body: "Already covered."},
            {path: "src/selected.py", line: 42, body: "Canonical body.\n\nKeep this paragraph."}
        ],
        unmapped_comments: [],
        withheld: [],
        all_withheld: false,
        clean: false
    }' > "$ARTIFACTS/finding-publication.json"
    echo '[1]' > "$ARTIFACTS/draft-selected-indices.json"
    jq -n '{mappings: [{path: "src/selected.py", line: 42, side: "RIGHT"}]}' > "$ARTIFACTS/draft-mappings.json"
    jq -n '{owner: "org", repo: "repo", pr_number: 42, reviewer_username: "reviewer", summary: "One issue inline."}' > "$ARTIFACTS/draft-context.json"
    extract_documented_block "$SKILL/handlers/review-pr-output.md" bash draft-assembly-input.json > "$ARTIFACTS/draft.sh"

    run bash -e "$ARTIFACTS/draft.sh"

    [ "$status" -eq 0 ]
    jq -e '.publication.comments | length == 2' "$ARTIFACTS/draft-assembly-input.json"
    jq -e '.owner == "org" and .pr_number == 42 and .comments == [{path: "src/selected.py", line: 42, side: "RIGHT", body: "Canonical body.\n\nKeep this paragraph."}]' "$ARTIFACTS/draft-input.json"
}

@test "handler contracts: comprehension example passes the detailed final gate" {
    jq '[{
        id: 1,
        severity: "blocking",
        comment_style: "detailed",
        location: "flag_matching.rs:262",
        file: "flag_matching.rs",
        line: 262,
        description: .desired_description,
        proposed_fix: null,
        facts: .facts
    }]' "$PROJECT_ROOT/tests/fixtures/finding-comments/pr-90970.json" > "$ARTIFACTS/finding.json"
    extract_documented_block "$PROJECT_ROOT/agents/comprehension-gate.md" json '"coverage"' > "$ARTIFACTS/verdicts.json"
    "$SKILL/scripts/finding-comment-contract.py" compose "$ARTIFACTS/finding.json" > "$ARTIFACTS/composed.json"

    run "$SKILL/scripts/finding-comment-contract.py" gate --final "$ARTIFACTS/composed.json" "$ARTIFACTS/verdicts.json"

    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.findings | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.findings[0].quality_state')" = "passed" ]
    [ "$(echo "$output" | jq -r '.findings[0].publishable')" = "true" ]
    [ "$(echo "$output" | jq '.withheld | length')" -eq 0 ]
}
