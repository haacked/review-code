#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SKILL="$PROJECT_ROOT/skills/review-code"
    ARTIFACTS="$BATS_TEST_TMPDIR/artifacts with spaces"
    mkdir -p "$ARTIFACTS"
    REVIEW_DIFF="$ARTIFACTS/review.patch"
    cat > "$REVIEW_DIFF" <<'PATCH'
diff --git a/backend/api.py b/backend/api.py
index 1111111..2222222 100644
--- a/backend/api.py
+++ b/backend/api.py
@@ -1 +1 @@
-old value
+new value
PATCH
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

# The redirection opens the FIFO for reading and writing.
# The command's stdin never reaches EOF because its own write end stays open.
# A command that reads stdin hangs until the alarm kills it with status 142.
run_with_open_stdin() {
    local fifo="$BATS_TEST_TMPDIR/stdin.fifo"
    mkfifo "$fifo"
    run perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 10 "$@" <> "$fifo"
}

@test "handler contracts: routing evidence reaches dispatch and survives session cleanup" {
    SESSION_FILE="$ARTIFACTS/session.json"
    architectural_context_path="$ARTIFACTS/explorer.md"
    review_file="$BATS_TEST_TMPDIR/saved review.md"
    printf '%s\n' '{"diff_tokens":100}' > "$SESSION_FILE"
    cat > "$architectural_context_path" <<'EOF'
Context summary stays on disk.
```review-routing
{"scope":"full","areas":{"frontend":{"status":"not_applicable","evidence":[{"check":"Read worker.py and searched callers across the repository","result":"Only server workers call the changed function; no UI consumers or browser behavior"}]},"security":{"status":"uncertain"}}}
```
EOF
    extract_documented_block "$SKILL/handlers/review-routing.md" bash classify-review-scope.sh > "$ARTIFACTS/route.sh"
    run env SESSION_FILE="$SESSION_FILE" review_diff_path="$REVIEW_DIFF" architectural_context_path="$architectural_context_path" bash -e "$ARTIFACTS/route.sh"
    [ "$status" -eq 0 ]
    jq -e '.skipped_agents == ["frontend"] and (.agents | contains(["correctness", "security"]))' "$ARTIFACTS/review-routing.json"
    agents=$(jq -r '.agents | join(" ")' "$ARTIFACTS/review-routing.json")
    run python3 "$SKILL/scripts/review-dispatch-plan.py" --fields "$SESSION_FILE" --agents "$agents"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e '[.agents[].area] | contains(["correctness", "security"]) and (index("frontend") == null)'

    mkdir -p "${review_file}.artifacts/session-123"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash 'cp ' \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/retain-routing.sh"
    run env review_file="$review_file" bash -e "$ARTIFACTS/retain-routing.sh"
    [ "$status" -eq 0 ]
    rm -rf "$ARTIFACTS"
    jq -e '.agent_decisions.frontend | .decision == "skip" and (.evidence[0].check | contains("worker.py"))' "${review_file}.artifacts/session-123/review-routing.json"
}

@test "handler contracts: routing follows exploration and empty scoped diffs do not skip reviewers" {
    run python3 - "$SKILL/handlers" <<'PY'
import sys
from pathlib import Path

handlers = Path(sys.argv[1])
review = (handlers / "review.md").read_text()
assert review.index("### Gather Architectural Context") < review.index("review-routing.md") < review.index("scripts/review-dispatch-plan.py")
assert "REVIEW_FIELDS.diff_path" in review
fallback = review.split("If `scoped_diffs` has no entry", 1)[1].split("\n\n", 1)[0]
assert "dispatch it against the returned `diff_path` with `diff_lines`" in fallback
assert "Drop it" not in fallback
routing = (handlers / "review-routing.md").read_text()
assert '--area "$area"' in routing
for manual_override in (
    "Mark all other areas as skipped",
    "Update the saved JSON's",
):
    assert manual_override not in routing
assert 'Each chunk analysis produces its own routing evidence' in routing
chunked = (handlers / "review-chunked.md").read_text()
assert 'for each agent in `$chunk.classification.agents`' in chunked
PY
    [ "$status" -eq 0 ]
}

@test "handler contracts: explicit security routing also keeps correctness" {
    SESSION_FILE="$ARTIFACTS/session.json"
    architectural_context_path="$ARTIFACTS/explorer.md"
    printf '%s\n' '{"diff_tokens":3000}' > "$SESSION_FILE"
    cat > "$architectural_context_path" <<'EOF'
```review-routing
{"scope":"full","areas":{"security":{"status":"not_applicable","evidence":[{"check":"Read every changed file","result":"No security-sensitive path changed."}]},"performance":{"status":"applies"}}}
```
EOF
    extract_documented_block "$SKILL/handlers/review-routing.md" bash classify-review-scope.sh > "$ARTIFACTS/route.sh"

    run env SESSION_FILE="$SESSION_FILE" review_diff_path="$REVIEW_DIFF" architectural_context_path="$architectural_context_path" area=security bash -e "$ARTIFACTS/route.sh"

    [ "$status" -eq 0 ]
    jq -e '
        (.agents | sort) == ["correctness", "security"] and
        (.skipped_agents | length) == 7 and
        (.reasoning | ascii_downcase | contains("explicit user scope override")) and
        .agent_decisions.correctness.decision == "run" and
        (.agent_decisions.correctness.reason | ascii_downcase | contains("correctness always runs")) and
        (.agent_decisions.correctness.reason | ascii_downcase | contains("explicit user scope override") | not) and
        .agent_decisions.security.decision == "run" and
        (.agent_decisions.security.reason | ascii_downcase | contains("explicit user scope override")) and
        ([.skipped_agents[] as $area |
            .agent_decisions[$area].decision == "skip" and
            (.agent_decisions[$area].reason | ascii_downcase | contains("explicit user scope override")) and
            .agent_decisions[$area].evidence == []] | all)
    ' "$ARTIFACTS/review-routing.json"
}

@test "handler contracts: routing without an explicit area uses explorer evidence" {
    SESSION_FILE="$ARTIFACTS/session.json"
    architectural_context_path="$ARTIFACTS/explorer.md"
    printf '%s\n' '{"diff_tokens":3000}' > "$SESSION_FILE"
    cat > "$architectural_context_path" <<'EOF'
```review-routing
{"scope":"full","areas":{"security":{"status":"not_applicable","evidence":[{"check":"Read every changed file","result":"Only documentation text changed; no executable or deployment files changed."}]},"correctness":{"status":"not_applicable","evidence":[{"check":"Read every changed file","result":"Only documentation text changed; no executable or deployment files changed."}]}}}
```
EOF
    extract_documented_block "$SKILL/handlers/review-routing.md" bash classify-review-scope.sh > "$ARTIFACTS/route.sh"

    run env SESSION_FILE="$SESSION_FILE" review_diff_path="$REVIEW_DIFF" architectural_context_path="$architectural_context_path" area= bash -e "$ARTIFACTS/route.sh"

    [ "$status" -eq 0 ]
    jq -e '
        .exploration_depth == "minimal" and
        (.agents | length) == 8 and
        (.agents | index("correctness")) != null and
        .skipped_agents == ["security"] and
        .agent_decisions.correctness.decision == "run" and
        (.agent_decisions.correctness.reason | ascii_downcase | contains("correctness always runs")) and
        .agent_decisions.security.decision == "skip" and
        (.agent_decisions.security.evidence | length) == 1
    ' "$ARTIFACTS/review-routing.json"
}

@test "handler contracts: documented reviewer report command separates evidence from findings" {
    report_path="$ARTIFACTS/report.json"
    report_name="correctness"
    jq -n '{investigation: "Full investigation", findings: "Complete findings", coverage: {files_read: ["src/example.py"], gaps: []}, open_from_others: []}' > "$report_path"
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
reviewers: correctness,testing
custom: keep
-->
# Earlier findings

# Appended full review
EOF
    extract_documented_block "$SKILL/handlers/review-compose.md" bash metadata_args \
        | sed 's/<REVIEW_FIELDS.reviewers joined with commas, or empty>//' > "$ARTIFACTS/metadata.sh"

    run env review_file="$review_file" review_commit=new-head bash -e "$ARTIFACTS/metadata.sh"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^<!-- review-metadata$' "$review_file")" -eq 1 ]
    grep -Fxq 'review_commit: new-head' "$review_file"
    grep -Fxq 'review_mode: full' "$review_file"
    grep -Fxq 'custom: keep' "$review_file"
    grep -Fxq '# Earlier findings' "$review_file"
    grep -Fxq '# Appended full review' "$review_file"
    ! grep -q '^delta_from:' "$review_file"
    ! grep -q '^reviewers:' "$review_file"
}

@test "handler contracts: a full review records the caller's reviewer list in its metadata" {
    review_file="$ARTIFACTS/review.md"
    printf '# Review\n' > "$review_file"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash metadata_args \
        | sed 's/<REVIEW_FIELDS.reviewers joined with commas, or empty>/correctness,testing/' > "$ARTIFACTS/metadata.sh"

    run env review_file="$review_file" review_commit=new-head bash -e "$ARTIFACTS/metadata.sh"

    [ "$status" -eq 0 ]
    grep -Fxq 'reviewers: correctness,testing' "$review_file"
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
    jq -n '{investigation: "Evidence", findings: "Finding", coverage: {files_read: ["a.py"], gaps: ["Cannot verify b.py"]}, open_from_others: []}' > "$ARTIFACTS/reports/security.json"
    printf '%s\n' "$ARTIFACTS/reports/security.json" > "$ARTIFACTS/expected-reviewer-reports.txt"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash reviewer-report.py \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/retain.sh"

    run env review_file="$review_file" bash -e "$ARTIFACTS/retain.sh"

    [ "$status" -eq 0 ]
    rm -rf "$ARTIFACTS"
    [ "$(cat "${review_file}.artifacts/session-123/investigations/security.md")" = "Evidence" ]
    jq -e '.gaps == ["Cannot verify b.py"]' "${review_file}.artifacts/session-123/coverage/security.json"
    [ "$(jq -c '.' "${review_file}.artifacts/session-123/open-from-others/security.json")" = '[]' ]
}

@test "handler contracts: documented synthesis merge groups open problems by link, location, and commenter" {
    local thread="https://github.com/org/repo/pull/1#discussion_r1"
    local pr="https://github.com/org/repo/pull/1"
    mkdir -p "$ARTIFACTS/open-from-others"
    jq -n --arg thread "$thread" --arg pr "$pr" '[
        {location: "posthog/deletion.py:88", raised_by: "@frank", link: $thread,
         problem: "Deleting by person_id misses rows in the materialized column at posthog/deletion.py:88.",
         assessment: "valid", severity: "blocking", why_not_reraised: "The thread is open."},
        {location: "PR", raised_by: "@alice", link: $pr,
         problem: "The migration at posthog/migrations/0042.py:12 has no rollback.",
         assessment: "unsure", severity: "question", why_not_reraised: "The review summary already asks for it."},
        {location: "PR", raised_by: "@bob", link: $pr,
         problem: "The deletion job at posthog/tasks/delete.py:30 has no retry.",
         assessment: "valid", severity: "suggestion", why_not_reraised: "The review summary is still open."}
    ]' > "$ARTIFACTS/open-from-others/chunk-1-correctness.json"
    jq -n --arg thread "$thread" '[
        {location: "posthog/deletion.py:88", raised_by: "@frank", link: $thread,
         problem: "Rows left behind at posthog/deletion.py:88 keep personal data after a deletion request.",
         assessment: "valid", severity: "suggestion", why_not_reraised: "Correctness owns the deletion path."}
    ]' > "$ARTIFACTS/open-from-others/security.json"
    extract_documented_block "$SKILL/handlers/review-synthesis.md" bash open-from-others > "$ARTIFACTS/merge.sh"

    run bash -e "$ARTIFACTS/merge.sh"

    [ "$status" -eq 0 ]
    [ "$output" = '{"count": 3}' ]
    jq -e --arg thread "$thread" --arg pr "$pr" '
        length == 3 and
        (.[] | select(.link == $thread) |
            .location == "posthog/deletion.py:88" and .raised_by == "@frank" and
            .assessments == [
                {reviewer: "correctness", problem: "Deleting by person_id misses rows in the materialized column at posthog/deletion.py:88.",
                 assessment: "valid", severity: "blocking", why_not_reraised: "The thread is open."},
                {reviewer: "security", problem: "Rows left behind at posthog/deletion.py:88 keep personal data after a deletion request.",
                 assessment: "valid", severity: "suggestion", why_not_reraised: "Correctness owns the deletion path."}
            ]) and
        ([.[] | select(.link == $pr) | .raised_by] | sort) == ["@alice", "@bob"] and
        (.[] | select(.raised_by == "@bob") |
            .assessments[0].problem == "The deletion job at posthog/tasks/delete.py:30 has no retry.")
    ' "$ARTIFACTS/open-from-others.json"
}

@test "handler contracts: documented synthesis merge keeps every problem one review summary raised" {
    local pr="https://github.com/org/repo/pull/1"
    mkdir -p "$ARTIFACTS/open-from-others"
    jq -n --arg pr "$pr" '[
        {location: "PR", raised_by: "@alice", link: $pr, problem: "The deletion job has no retry.",
         assessment: "valid", severity: "suggestion", why_not_reraised: "The review summary is open."},
        {location: "PR", raised_by: "@alice", link: $pr, problem: "The migration has no rollback.",
         assessment: "valid", severity: "suggestion", why_not_reraised: "The review summary is open."}
    ]' > "$ARTIFACTS/open-from-others/code-reviewer-correctness.json"
    extract_documented_block "$SKILL/handlers/review-synthesis.md" bash open-from-others > "$ARTIFACTS/merge.sh"

    run bash -e "$ARTIFACTS/merge.sh"

    [ "$status" -eq 0 ]
    jq -e '
        length == 1 and
        ([.[0].assessments[].problem] | sort) == ["The deletion job has no retry.", "The migration has no rollback."]
    ' "$ARTIFACTS/open-from-others.json"
}

@test "handler contracts: documented synthesis merge writes an empty list without reading stdin" {
    mkdir -p "$ARTIFACTS/open-from-others"
    extract_documented_block "$SKILL/handlers/review-synthesis.md" bash open-from-others > "$ARTIFACTS/merge.sh"

    run_with_open_stdin bash -e "$ARTIFACTS/merge.sh"

    [ "$status" -eq 0 ]
    [ "$(jq -c '.' "$ARTIFACTS/open-from-others.json")" = '[]' ]
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
    jq -n '{investigation: "Evidence", findings: "Finding", coverage: {files_read: ["a.py"], gaps: []}, open_from_others: []}' > "$ARTIFACTS/reports/security.json"
    printf '%s\n' "$ARTIFACTS/reports/security.json" "$ARTIFACTS/reports/correctness.json" > "$ARTIFACTS/expected-reviewer-reports.txt"
    extract_documented_block "$SKILL/handlers/review-compose.md" bash reviewer-report.py \
        | sed 's/<SESSION_ID>/session-123/g' > "$ARTIFACTS/retain.sh"

    run env review_file="$review_file" bash -e "$ARTIFACTS/retain.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"correctness.json"* ]]
}

@test "handler contracts: documented wording lint writes the repair input for repair ids only" {
    jq -n '{
        findings: [
            {id: 1, severity: "blocking", comment_style: "concise", description: "`blocking`: The cache stays stale for 300 seconds.", proposed_fix: null, facts: {}},
            {id: 2, severity: "nit", comment_style: "concise", description: "`nit`: This pins the behavior.", proposed_fix: null, facts: {}, reasons: ["Stale preflight reason."], unresolved: [{phrase: "this", stands_for: "x"}]}
        ],
        rewrites_needed: [],
        withheld: [{id: 3, description: "`nit`: This pins the behavior."}]
    }' > "$ARTIFACTS/finding-quality-composed.json"
    extract_documented_block "$SKILL/handlers/review-finding-quality.md" bash voice-lint-result.json > "$ARTIFACTS/lint.sh"

    run bash -e "$ARTIFACTS/lint.sh"

    [ "$status" -eq 0 ]
    jq -e '.error == null and .checked == 2 and .clean == 1 and .repair_ids == [2]' <<<"$output"
    jq -e '.error == null and .findings[0].id == 2' "$ARTIFACTS/voice-lint-result.json"
    jq -e '
        length == 1 and .[0].id == 2 and .[0].facts == {}
        and (.[0].reasons | length > 0 and all(.[]; contains("Stale") | not))
        and (.[0] | has("unresolved") | not)
    ' "$ARTIFACTS/lint-repair-input.json"
}

@test "handler contracts: finding stages dispatch input and source context through file references" {
    local agent stage prompt_file
    local diff_path="$ARTIFACTS/diff.patch"
    printf '%s\n' 'DIFF_PAYLOAD_SENTINEL' > "$diff_path"
    printf '%s\n' 'BRIEFING_PAYLOAD_SENTINEL' > "$ARTIFACTS/briefing.md"
    printf '%s\n' 'FILE_ACCESS_PAYLOAD_SENTINEL' > "$ARTIFACTS/file-access.md"
    extract_documented_block "$SKILL/handlers/review-finding-quality.md" bash build-finding-prompt.py > "$ARTIFACTS/quality.sh"

    for agent in comprehension-gate code-reviewer-comment; do
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
    run python3 - "$SKILL/handlers/review-finding-quality.md" <<'PY'
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

@test "handler contracts: documented routing applies the session's caller reviewer list" {
    SESSION_FILE="$ARTIFACTS/session.json"
    architectural_context_path="$ARTIFACTS/explorer.md"
    printf '%s\n' '{"diff_tokens":3000,"reviewers":["correctness","testing"]}' > "$SESSION_FILE"
    cat > "$architectural_context_path" <<'CONTEXT'
```review-routing
{"scope":"full","areas":{"testing":{"status":"not_applicable","evidence":[{"check":"Read every changed file","result":"No test changed."}]},"security":{"status":"applies"}}}
```
CONTEXT
    extract_documented_block "$SKILL/handlers/review-routing.md" bash classify-review-scope.sh > "$ARTIFACTS/route.sh"

    run env SESSION_FILE="$SESSION_FILE" review_diff_path="$REVIEW_DIFF" architectural_context_path="$architectural_context_path" bash -e "$ARTIFACTS/route.sh"

    [ "$status" -eq 0 ]
    jq -e '
        .agents == ["correctness", "testing"] and
        .agent_decisions.security.decision == "skip" and
        (.agent_decisions.security.reason | contains("Excluded by the caller")) and
        .agent_decisions.security.evidence == []
    ' "$ARTIFACTS/review-routing.json"
}

@test "handler contracts: documented contract command publishes reviewer bodies when the gates are skipped" {
    jq '[{
        id: 1, agent: "correctness", severity: "suggestion", comment_style: "concise",
        location: "backend/api.py:1", file: "backend/api.py", line: 1, side: "RIGHT",
        confidence: 85, validator_confirmed: false,
        description: "`suggestion`: the reviewer body", proposed_fix: null,
        facts: {problem: "p", trigger: null, mechanism: ["m"], result: "r",
                requested_change: "c", regression_case: null, regression_rationale: null}
    }]' -n > "$ARTIFACTS/finding-contract-input.json"
    extract_documented_block "$SKILL/handlers/review-finding-quality.md" bash finding-contract-validated.json > "$ARTIFACTS/contract.template"

    sed 's/<REVIEW_FIELDS.comment_gates>/skip/' "$ARTIFACTS/contract.template" > "$ARTIFACTS/contract.sh"
    run bash -e "$ARTIFACTS/contract.sh"
    [ "$status" -eq 0 ]
    jq -e '.findings[0].publishable == true and .findings[0].quality_state == "gates_skipped" and .findings[0].description == "`suggestion`: the reviewer body"' "$ARTIFACTS/finding-contract-validated.json"

    sed 's/<REVIEW_FIELDS.comment_gates>/run/' "$ARTIFACTS/contract.template" > "$ARTIFACTS/contract.sh"
    run bash -e "$ARTIFACTS/contract.sh"
    [ "$status" -eq 0 ]
    jq -e '.findings[0].publishable == false and .findings[0].quality_state == "ungated"' "$ARTIFACTS/finding-contract-validated.json"
}

@test "handler contracts: SKILL.md documents no PR file pattern example" {
    run grep -nE '/review-code [0-9]+ "' "$SKILL/SKILL.md"
    [ "$status" -eq 1 ]
}
