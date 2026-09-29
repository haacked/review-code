#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SKILL="$PROJECT_ROOT/skills/review-code"
    ARTIFACTS="$BATS_TEST_TMPDIR/artifacts with spaces"
    mkdir -p "$ARTIFACTS"
    cat > "$ARTIFACTS/briefing.md" << 'EOF'
# Review briefing

Review the changed files and report findings with supporting evidence.

## Soft Reviewer Work Budget

Report budget counts and any coverage gaps.
EOF
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

assert_briefing_rejected() {
    local handler="$1"
    local report_name="security"
    local report_path="$ARTIFACTS/reports/$report_name.json"
    local review_file="$BATS_TEST_TMPDIR/saved review.md"
    local evidence_dir="$ARTIFACTS"
    if [ "$handler" = review-compose ]; then
        evidence_dir="${review_file}.artifacts/session-123"
    fi
    mkdir -p "$ARTIFACTS/reports"
    jq -n '{investigation: "Evidence", findings: "", coverage: {files_read: ["src/example.py"], gaps: []}}' > "$report_path"
    printf '%s\n' "$report_path" > "$ARTIFACTS/expected-reviewer-reports.txt"
    extract_documented_block "$SKILL/handlers/$handler.md" bash reviewer-report.py \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/check-briefing.sh"

    run env PATH="$ARTIFACTS/bin:$PATH" report_path="$report_path" report_name="$report_name" review_file="$review_file" bash -e "$ARTIFACTS/check-briefing.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *BRIEFING_UNAVAILABLE* ]]
    [ ! -e "$evidence_dir/findings/$report_name.md" ]
    [ ! -e "$evidence_dir/investigations/$report_name.md" ]
    [ ! -e "$evidence_dir/coverage/$report_name.json" ]
}

stub_briefing_read_error() {
    mkdir -p "$ARTIFACTS/bin"
    cat > "$ARTIFACTS/bin/grep" << 'EOF'
#!/usr/bin/env bash
echo 'simulated briefing read failure' >&2
exit 2
EOF
    chmod +x "$ARTIFACTS/bin/grep"
}

@test "handler contracts: documented reviewer report command separates evidence from findings" {
    report_path="$ARTIFACTS/report.json"
    report_name="correctness"
    jq -n '{investigation: "Full investigation", findings: "Complete findings", coverage: {files_read: ["src/example.py"], gaps: [], budget: {tool_calls: 2, searches: 0, status: "complete"}}}' > "$report_path"
    extract_documented_block "$SKILL/handlers/reviewer-output.md" bash reviewer-report.py > "$ARTIFACTS/report.sh"

    run env report_path="$report_path" report_name="$report_name" bash -e "$ARTIFACTS/report.sh"

    [ "$status" -eq 0 ]
    [ "$(cat "$ARTIFACTS/findings/correctness.md")" = "Complete findings" ]
    [ "$(cat "$ARTIFACTS/investigations/correctness.md")" = "Full investigation" ]
    [[ "$output" != *"Full investigation"* ]]
}

@test "handler contracts: reviewer output accepts an in-flight report from before budget accounting" {
    report_path="$ARTIFACTS/report.json"
    report_name="correctness"
    printf '%s\n' '# Review briefing' '' 'Review the changed files and report findings with supporting evidence.' > "$ARTIFACTS/briefing.md"
    jq -n '{investigation: "Evidence", findings: "", coverage: {files_read: ["src/example.py"], gaps: []}}' > "$report_path"
    extract_documented_block "$SKILL/handlers/reviewer-output.md" bash reviewer-report.py > "$ARTIFACTS/report.sh"

    run env report_path="$report_path" report_name="$report_name" bash -e "$ARTIFACTS/report.sh"

    [ "$status" -eq 0 ]
    jq -e 'has("budget") | not' <<< "$output"
}

@test "handler contracts: reviewer output requires budget accounting for a new briefing" {
    report_path="$ARTIFACTS/report.json"
    report_name="correctness"
    jq -n '{investigation: "Evidence", findings: "", coverage: {files_read: ["src/example.py"], gaps: []}}' > "$report_path"
    extract_documented_block "$SKILL/handlers/reviewer-output.md" bash reviewer-report.py > "$ARTIFACTS/report.sh"

    run env report_path="$report_path" report_name="$report_name" bash -e "$ARTIFACTS/report.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *budget* ]]
}

@test "handler contracts: reviewer output rejects a missing briefing" {
    rm "$ARTIFACTS/briefing.md"

    assert_briefing_rejected reviewer-output
}

@test "handler contracts: reviewer output rejects an empty briefing" {
    : > "$ARTIFACTS/briefing.md"

    assert_briefing_rejected reviewer-output
}

@test "handler contracts: reviewer output rejects a directory at the briefing path" {
    rm "$ARTIFACTS/briefing.md"
    mkdir "$ARTIFACTS/briefing.md"

    assert_briefing_rejected reviewer-output
}

@test "handler contracts: reviewer output rejects a briefing read error" {
    stub_briefing_read_error

    assert_briefing_rejected reviewer-output
    [[ "$output" == *'simulated briefing read failure'* ]]
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

@test "handler contracts: reviewer output preserves batch dispatch and completion rules" {
    python3 - "$SKILL/handlers/reviewer-output.md" << 'PY'
from pathlib import Path
import re
import sys

document = Path(sys.argv[1]).read_text()
dispatch = document.split("For Codex,", 1)[1].split("After each successful dispatch", 1)[0]
assert "agent-dispatch.sh batch" in dispatch
assert re.search(r"(?:parallel|concurrent).{0,100}(?:batch|manifest)|(?:batch|manifest).{0,100}(?:parallel|concurrent)", dispatch, re.I | re.S)
assert re.search(r"output_file.{0,30}\$report_path", dispatch, re.S)
run_rule = re.search(r"[^.\n]*agent-dispatch\.sh run[^.\n]*(?:\.|$)", dispatch)
assert run_rule is not None
assert re.search(r"\b(?:lone|single)\b", run_rule[0]) and "retry" in run_rule[0]
assert "review.md" in dispatch and "completion" in dispatch.lower()
PY
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

@test "handler contracts: compose delegates timestamp generation to the metadata writer" {
    extract_documented_block "$SKILL/handlers/review-compose.md" bash metadata_args > "$ARTIFACTS/metadata.sh"

    run grep -Eq '(^|[^[:alnum:]_])date([[:space:]]|$)|reviewed_at=' "$ARTIFACTS/metadata.sh"
    [ "$status" -ne 0 ]
    grep -Fq 'update-review-metadata.sh' "$ARTIFACTS/metadata.sh"
}

@test "handler contracts: review dispatch waits through its owning harness" {
    python3 - "$SKILL/handlers/review.md" << 'PY'
from pathlib import Path
import re
import sys

document = Path(sys.argv[1]).read_text()
dispatch = document.split("### Subagent Availability\n", 1)[1].split("### Gather Architectural Context\n", 1)[0]
claude = dispatch.split("**Claude ($harness = `claude`):**", 1)[1].split("**Codex ($harness = `codex`):**", 1)[0]
codex = dispatch.split("**Codex ($harness = `codex`):**", 1)[1]
assert "completion notification" in claude.lower()
assert re.search(r"blocking.{0,60}(?:wait|TaskOutput)|(?:wait|TaskOutput).{0,60}blocking", claude, re.I | re.S)
assert "agent-dispatch.sh" in codex and re.search(r"\bbatch\b", codex)
assert "same shell" in codex.lower()
assert re.search(r"(?:every|each).{0,70}(?:exit|status)|(?:exit|status).{0,70}(?:every|each)", codex, re.I | re.S)
assert re.search(r"(?:no-op|no op|noop|throwaway)", dispatch, re.I)
for command in ("true", "sleep", "echo waiting"):
    assert command in dispatch, f"missing explicit prohibition of {command!r} glue turns"
for block in re.findall(r"^```bash\n(.*?)^```$", document, re.M | re.S):
    assert not re.search(r"^\s*(?:true|sleep\s+1|echo\s+['\"]?waiting['\"]?)\s*$", block, re.M)
PY
}

@test "handler contracts: retained reviewer evidence survives session cleanup" {
    review_file="$BATS_TEST_TMPDIR/saved review.md"
    mkdir -p "$ARTIFACTS/reports"
    jq -n '{investigation: "Evidence", findings: "Finding", coverage: {files_read: ["a.py"], gaps: ["Cannot verify b.py"], budget: {tool_calls: 2, searches: 0, status: "complete"}}}' > "$ARTIFACTS/reports/security.json"
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
    jq -n '{investigation: "Evidence", findings: "Finding", coverage: {files_read: ["a.py"], gaps: [], budget: {tool_calls: 2, searches: 0, status: "complete"}}}' > "$ARTIFACTS/reports/security.json"
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

@test "handler contracts: finding stages dispatch input and source context through file references" {
    local agent stage prompt_file
    local diff_path="$ARTIFACTS/diff.patch"
    printf '%s\n' 'DIFF_PAYLOAD_SENTINEL' > "$diff_path"
    printf '%s\n' 'BRIEFING_PAYLOAD_SENTINEL' > "$ARTIFACTS/briefing.md"
    printf '%s\n' 'FILE_ACCESS_PAYLOAD_SENTINEL' > "$ARTIFACTS/file-access.md"
    extract_documented_block "$SKILL/handlers/review-finding-quality.md" bash build-finding-prompt.py > "$ARTIFACTS/quality.sh"

    for agent in comprehension-gate code-reviewer-voice code-reviewer-comment; do
        stage="test-$agent"
        prompt_file="$ARTIFACTS/$stage-prompt.md"
        jq -n '[{id: 1, description: "FINDING_PAYLOAD_SENTINEL"}]' > "$ARTIFACTS/$stage-input.json"

        run env quality_stage="$stage" quality_agent="$agent" diff_path="$diff_path" bash -e "$ARTIFACTS/quality.sh"

        [ "$status" -eq 0 ]
        [ -s "$prompt_file" ]
        grep -Fq "$ARTIFACTS/$stage-input.json" "$prompt_file"
        ! grep -q 'PAYLOAD_SENTINEL' "$prompt_file"
        [[ "$output" != *PAYLOAD_SENTINEL* ]]
        if [ "$agent" = code-reviewer-comment ]; then
            grep -Fq "$diff_path" "$prompt_file"
            grep -Fq "$ARTIFACTS/briefing.md" "$prompt_file"
            grep -Fq "$ARTIFACTS/file-access.md" "$prompt_file"
        else
            ! grep -Fq "$diff_path" "$prompt_file"
            ! grep -Fq "$ARTIFACTS/briefing.md" "$prompt_file"
            ! grep -Fq "$ARTIFACTS/file-access.md" "$prompt_file"
        fi
    done
}

@test "handler contracts: finding quality Codex dispatch uses the installed helper path" {
    run python3 - "$SKILL/handlers/review-finding-quality.md" << 'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
codex_line = next(line for line in text.splitlines() if line.startswith('- **Codex:**'))
expected = '~/.agents/skills/review-code/scripts/helpers/agent-dispatch.sh run "$quality_agent" "$quality_prompt" "$quality_output"'
assert expected in codex_line
assert '`agent-dispatch.sh run ' not in codex_line
PY

    [ "$status" -eq 0 ]
}

@test "handler contracts: unavailable finding input stops the documented block before dispatch" {
    local marker="$ARTIFACTS/dispatched"
    extract_documented_block "$SKILL/handlers/review-finding-quality.md" bash build-finding-prompt.py > "$ARTIFACTS/quality.sh"
    printf '%s\n' 'touch "$DISPATCH_MARKER"' >> "$ARTIFACTS/quality.sh"

    run env quality_stage=missing quality_agent=comprehension-gate DISPATCH_MARKER="$marker" bash -e "$ARTIFACTS/quality.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *INPUT_UNAVAILABLE* ]]
    [ ! -e "$marker" ]
    [ ! -s "$ARTIFACTS/missing-prompt.md" ]
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

@test "handler contracts: documented preservation merge restores lost claims" {
    jq '{findings: [.cases[] | {id, severity: "blocking", description, proposed_fix: null}], withheld: []}' "$PROJECT_ROOT/tests/fixtures/finding-comments/voice-preservation-regressions.json" > "$ARTIFACTS/finding-quality-prevoice.json"
    jq '[.cases[] | {id, description: .rewrite, proposed_fix: null, unchanged: false}]' "$PROJECT_ROOT/tests/fixtures/finding-comments/voice-preservation-regressions.json" > "$ARTIFACTS/voice-output.md"
    jq '[.cases[] | {id, preserved: false, notes}]' "$PROJECT_ROOT/tests/fixtures/finding-comments/voice-preservation-regressions.json" > "$ARTIFACTS/voice-preservation.json"
    extract_documented_block "$SKILL/handlers/review-finding-quality.md" bash '"<artifacts_dir>/voice-output.md"' > "$ARTIFACTS/preserve.sh"

    run bash -e "$ARTIFACTS/preserve.sh"

    [ "$status" -eq 0 ]
    jq -e '.voice_preservation.error == null and (.voice_preservation.reverted | length) == 2' "$ARTIFACTS/finding-quality-voiced.json"
    jq -e --slurpfile original "$ARTIFACTS/finding-quality-prevoice.json" '.findings == $original[0].findings and .withheld == $original[0].withheld' "$ARTIFACTS/finding-quality-voiced.json"
}

@test "handler contracts: documented voice repair keeps accepted neighboring rewrites" {
    jq -n '{findings: [
        {id: 1, severity: "suggestion", description: "`suggestion`: Original one.", proposed_fix: null},
        {id: 2, severity: "suggestion", description: "`suggestion`: Original two.", proposed_fix: null}
    ], withheld: []}' > "$ARTIFACTS/finding-quality-prevoice.json"
    jq -n '{findings: [
        {id: 1, severity: "suggestion", description: "`suggestion`: First rewrite.", proposed_fix: null},
        {id: 2, severity: "suggestion", description: "`suggestion`: Accepted neighbor.", proposed_fix: null}
    ], withheld: []}' > "$ARTIFACTS/finding-quality-voiced.json"
    printf '%s\n' '{"warned_ids": [1], "error": null}' > "$ARTIFACTS/voice-lint-result.json"
    printf '%s\n' '[{"id": 1, "description": "`suggestion`: Repaired one.", "proposed_fix": null, "unchanged": false}]' > "$ARTIFACTS/voice-repair-output.md"
    printf '%s\n' '[{"id": 1, "preserved": true, "notes": "Same claim."}]' > "$ARTIFACTS/voice-repair-preservation.json"
    extract_documented_block "$SKILL/handlers/review-finding-quality.md" bash voice-repair-output.md > "$ARTIFACTS/repair.sh"

    run bash -e "$ARTIFACTS/repair.sh"

    [ "$status" -eq 0 ]
    jq -e '
        (.findings[] | select(.id == 1) | .description) == "`suggestion`: Repaired one."
        and (.findings[] | select(.id == 2) | .description) == "`suggestion`: Accepted neighbor."
        and .voice_repair.target_ids == [1]
    ' "$ARTIFACTS/finding-quality-repaired.json"
}

@test "handler contracts: retained budget gap names its chunk reviewer after cleanup" {
    review_file="$BATS_TEST_TMPDIR/saved review.md"
    mkdir -p "$ARTIFACTS/reports"
    jq -n '{investigation: "Evidence", findings: "", coverage: {files_read: ["a.py"], gaps: ["src/consumer.py: queue retry handling was not checked"], budget: {tool_calls: 60, searches: 12, status: "limited"}}}' > "$ARTIFACTS/reports/chunk-2-code-reviewer-correctness.json"
    printf '%s\n' "$ARTIFACTS/reports/chunk-2-code-reviewer-correctness.json" > "$ARTIFACTS/expected-reviewer-reports.txt"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash reviewer-report.py \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/retain.sh"

    run env review_file="$review_file" bash -e "$ARTIFACTS/retain.sh"

    [ "$status" -eq 0 ]
    grep -Fq 'chunk-2-code-reviewer-correctness' "$ARTIFACTS/review-coverage.md"
    grep -Fq 'src/consumer.py: queue retry handling was not checked' "$ARTIFACTS/review-coverage.md"
    grep -Fq '60/60 tool calls' "$ARTIFACTS/review-coverage.md"
    rm -rf "$ARTIFACTS"
    grep -Fq 'src/consumer.py: queue retry handling was not checked' "${review_file}.artifacts/session-123/limitations/chunk-2-code-reviewer-correctness.md"
}

@test "handler contracts: compose refuses a new reviewer report without budget accounting" {
    review_file="$BATS_TEST_TMPDIR/saved review.md"
    mkdir -p "$ARTIFACTS/reports"
    jq -n '{investigation: "Evidence", findings: "", coverage: {files_read: [], gaps: []}}' > "$ARTIFACTS/reports/security.json"
    printf '%s\n' "$ARTIFACTS/reports/security.json" > "$ARTIFACTS/expected-reviewer-reports.txt"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash reviewer-report.py \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/retain.sh"

    run env review_file="$review_file" bash -e "$ARTIFACTS/retain.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *budget* ]]
}

@test "handler contracts: compose accepts an in-flight report from before budget accounting" {
    review_file="$BATS_TEST_TMPDIR/saved review.md"
    mkdir -p "$ARTIFACTS/reports"
    printf '%s\n' '# Review briefing' '' 'Review the changed files and report findings with supporting evidence.' > "$ARTIFACTS/briefing.md"
    jq -n '{investigation: "Evidence", findings: "", coverage: {files_read: [], gaps: []}}' > "$ARTIFACTS/reports/security.json"
    printf '%s\n' "$ARTIFACTS/reports/security.json" > "$ARTIFACTS/expected-reviewer-reports.txt"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash reviewer-report.py \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/retain.sh"

    run env review_file="$review_file" bash -e "$ARTIFACTS/retain.sh"

    [ "$status" -eq 0 ]
    jq -e 'has("budget") | not' <<< "$output"
}

@test "handler contracts: compose rejects a missing briefing" {
    rm "$ARTIFACTS/briefing.md"

    assert_briefing_rejected review-compose
}

@test "handler contracts: compose rejects an empty briefing" {
    : > "$ARTIFACTS/briefing.md"

    assert_briefing_rejected review-compose
}

@test "handler contracts: compose rejects a directory at the briefing path" {
    rm "$ARTIFACTS/briefing.md"
    mkdir "$ARTIFACTS/briefing.md"

    assert_briefing_rejected review-compose
}

@test "handler contracts: compose rejects a briefing read error" {
    stub_briefing_read_error

    assert_briefing_rejected review-compose
    [[ "$output" == *'simulated briefing read failure'* ]]
}

@test "handler contracts: static instructions require coverage disclosures in saved reviews and draft summaries" {
    run python3 - "$SKILL/handlers/review-compose.md" "$SKILL/handlers/review-pr-output.md" << 'PY'
import sys
from pathlib import Path

compose = Path(sys.argv[1]).read_text()
pr_output = Path(sys.argv[2]).read_text()

assert "include it verbatim under `## Coverage limitations`" in compose
assert "Do not describe a review with gaps as clean or fully checked" in compose
assert "include every reviewer and named coverage gap in the draft summary" in pr_output
assert "Say the review is incomplete" in pr_output
assert 'never use an unqualified "LGTM" with gaps' in pr_output
PY

    [ "$status" -eq 0 ]
}
