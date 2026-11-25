#!/usr/bin/env bats
# Tests for the spec-review track: the path table in helpers/review_tracks.py,
# the track guard in classify-review-scope.py, the spec-scoped briefing diff,
# and the code-reviewer-spec agent definition.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPTS="$PROJECT_ROOT/skills/review-code/scripts"
    CLASSIFY="$SCRIPTS/classify-review-scope.sh"
    FIXTURE="$PROJECT_ROOT/tests/fixtures/diffs/sdk-specs-251.diff"
    SPEC_AGENT="$PROJECT_ROOT/agents/code-reviewer-spec.md"
    export CLAUDE_SESSION_DIR="$BATS_TEST_TMPDIR/sessions"
    ARTIFACTS="$CLAUDE_SESSION_DIR/review-code/artifacts-tracks"
    SESSION="$CLAUDE_SESSION_DIR/review-code/review-code-12345-1234567890.json"
    CONTEXT="$BATS_TEST_TMPDIR/explorer.md"
    mkdir -p "$ARTIFACTS"
    ALL_AREAS='["security","performance","correctness","maintainability","testing","compatibility","infra-config","frontend","spec"]'
    ORIGINAL_AREAS='["security","performance","correctness","maintainability","testing","compatibility","infra-config","frontend"]'
    SPEC_TRACK_AGENTS='["compatibility","correctness","maintainability","spec"]'
    SPEC_TRACK_SKIPS='["frontend","infra-config","performance","security","testing"]'
    TABLE_CHECK='Classified every changed path with helpers/review_tracks.py'
}

# Writes stdin to the session's diff.patch and builds the session the way the
# orchestrator does: real pre-review-context.sh metadata and a top-level
# diff_path.
use_patch() {
    cat > "$ARTIFACTS/diff.patch"
    "$SCRIPTS/pre-review-context.sh" < "$ARTIFACTS/diff.patch" > "$BATS_TEST_TMPDIR/metadata.json"
    jq -n --arg dir "$ARTIFACTS" --slurpfile metadata "$BATS_TEST_TMPDIR/metadata.json" '{
        status: "ready",
        mode: "pr",
        artifacts_dir: $dir,
        diff_path: ($dir + "/diff.patch"),
        diff_tokens: 3000,
        file_metadata: $metadata[0],
        languages: {has_frontend: false},
        review_context: "Review the change.",
        pr: {number: 1, title: "Change", url: "https://example.com/1",
             author: "testuser", base: "main", head: "feature", state: "OPEN", body: "",
             comments: {conversation: [], reviews: [], inline: []}}
    }' > "$SESSION"
}

change_session() {
    jq "$@" "$SESSION" > "$BATS_TEST_TMPDIR/changed.json"
    mv "$BATS_TEST_TMPDIR/changed.json" "$SESSION"
}

modify_hunk() {
    local path="$1" added="${2:-new value}" removed="${3:-old value}"
    printf '%s\n' "diff --git a/$path b/$path" 'index 1111111..2222222 100644' \
        "--- a/$path" "+++ b/$path" '@@ -1 +1 @@' "-$removed" "+$added"
}

add_hunk() {
    local path="$1" added="${2:-new value}"
    printf '%s\n' "diff --git a/$path b/$path" 'new file mode 100644' 'index 0000000..2222222' \
        '--- /dev/null' "+++ b/$path" '@@ -0,0 +1 @@' "+$added"
}

delete_hunk() {
    local path="$1"
    printf '%s\n' "diff --git a/$path b/$path" 'deleted file mode 100644' 'index 1111111..0000000' \
        "--- a/$path" '+++ /dev/null' '@@ -1 +0,0 @@' '-retired value'
}

write_routing() {
    printf '# Explorer findings\n\n```review-routing\n%s\n```\n' "$1" > "$CONTEXT"
}

negative_evidence_for() {
    jq -nc --arg area "$1" '{scope: "full", areas: {($area): {status: "not_applicable",
        evidence: [{check: "Read every changed file", result: "Nothing in this area changed."}]}}}'
}

classify() {
    run "$CLASSIFY" "$SESSION" "$@"
    [ "$status" -eq 0 ]
}

assert_json() {
    printf '%s' "$output" | jq -e "$@"
}

assert_complete_decisions() {
    assert_json --argjson areas "$ALL_AREAS" '
        . as $result |
        (.agent_decisions | keys | sort) == ($areas | sort) and
        ([.agents[], .skipped_agents[]] | sort) == ($areas | sort) and
        all(.agents[]; $result.agent_decisions[.].decision == "run") and
        all(.skipped_agents[]; $result.agent_decisions[.].decision == "skip")
    '
}

assert_every_skip_has_evidence() {
    assert_json '. as $result | all(.skipped_agents[]; ($result.agent_decisions[.].evidence | length) > 0)'
}

# The code track with no explorer evidence keeps every original reviewer.
assert_code_track_full_review() {
    assert_json --argjson areas "$ORIGINAL_AREAS" '
        .track == "code" and
        ((.agents - ["spec"]) | sort) == ($areas | sort) and
        .agent_decisions.security.decision == "run" and
        .agent_decisions.testing.decision == "run" and
        .agent_decisions.performance.decision == "run"
    '
}

assert_spec_track() {
    assert_json --argjson agents "$SPEC_TRACK_AGENTS" '.track == "spec" and (.agents | sort) == $agents'
}

path_kinds() {
    python3 - "$SCRIPTS" "$@" <<'PY'
import json
import sys

sys.path.insert(0, sys.argv[1])
from helpers.review_tracks import path_kind

for path in sys.argv[2:]:
    kind, reason = path_kind(path)
    print(json.dumps({"path": path, "kind": kind, "reason": reason}))
PY
}

# Appends a spec-content hunk to a guard case so that only the guard's
# condition decides the track.
guard_case() {
    { modify_hunk docs/a.md; printf '%s' "$1"; } | use_patch
    classify
    assert_code_track_full_review
}

@test "table marks prose, Gherkin, schema, example, and OpenSpec metadata paths as spec" {
    paths=(docs/a.md x.MDX notes.rst acceptance/private/x.feature api/event.schema.json
        acceptance/private/exception-event-metadata.examples.json
        openspec/changes/archive/2026-x/.openspec.yaml)

    run path_kinds "${paths[@]}"

    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -s -e --argjson count "${#paths[@]}" '
        length == $count and
        all(.[]; .kind == "spec" and (.reason | type == "string" and test("\\S")))
    '
}

@test "table marks config, prompt, instruction, and source paths as code" {
    paths=(openspec/config.yaml config.example.yaml package.json examples/node/package.json
        schemas/user.json .github/PULL_REQUEST_TEMPLATE.md agents/code-reviewer-security.md
        skills/review-code/handlers/review.md CLAUDE.md docs/AGENTS.md .claude Makefile src/app.py)

    run path_kinds "${paths[@]}"

    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -s -e --argjson count "${#paths[@]}" '
        length == $count and
        all(.[]; .kind == "code" and (.reason | type == "string" and test("\\S")))
    '
}

@test "spec_paths keeps only spec content in input order" {
    run python3 - "$SCRIPTS" <<'PY'
import json
import sys

sys.path.insert(0, sys.argv[1])
from helpers.review_tracks import spec_paths

print(json.dumps(spec_paths(["a.md", "src/x.py", "b.feature", "agents/x.md"])))
PY

    [ "$status" -eq 0 ]
    [ "$output" = '["a.md", "b.feature"]' ]
}

@test "sdk-specs#251 has no patch blocker and no security term" {
    run python3 - "$SCRIPTS" "$FIXTURE" <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from helpers.review_tracks import parse_patch, security_hits

parsed = parse_patch(Path(sys.argv[2]).read_text())
print(json.dumps({"blockers": parsed["blockers"], "hits": security_hits(parsed, [])}))
PY

    [ "$status" -eq 0 ]
    assert_json '.blockers == [] and .hits == []'
}

@test "only helpers/review_tracks.py holds the path patterns" {
    run bash -c 'grep -rnE "openspec|\\.feature" "$1" | grep -v "review_tracks"' _ "$SCRIPTS"

    [ "$output" = "" ]
}

@test "sdk-specs#251 takes the spec track with correctness, spec, compatibility, and maintainability" {
    use_patch < "$FIXTURE"

    classify

    assert_complete_decisions
    assert_spec_track
    assert_every_skip_has_evidence
    assert_json --argjson skips "$SPEC_TRACK_SKIPS" --arg check "$TABLE_CHECK" '
        (.skipped_agents | sort) == $skips and
        .agent_decisions.security.decision == "skip" and
        .agent_decisions.performance.evidence[0].check == $check and
        (.agent_decisions.performance.evidence[0].result | contains("All 6 changed paths are spec content")) and
        (.reasoning | ascii_downcase | contains("spec"))
    '
}

@test "a session that nests or renames diff_path takes the code track" {
    use_patch < "$FIXTURE"
    cp "$SESSION" "$BATS_TEST_TMPDIR/orchestrator-session.json"

    for transform in \
        '.artifacts = {diff_path: .diff_path} | del(.diff_path)' \
        '.diff_file = .diff_path | del(.diff_path)' \
        '.review = {diff_path: .diff_path} | del(.diff_path)'; do
        cp "$BATS_TEST_TMPDIR/orchestrator-session.json" "$SESSION"
        change_session "$transform"
        echo "transform: $transform"
        classify
        assert_code_track_full_review
    done
}

@test "a mixed PR keeps the code track and adds the spec reviewer" {
    { modify_hunk src/app.py; modify_hunk docs/guide.md; } | use_patch

    classify

    assert_complete_decisions
    assert_json --argjson areas "$ORIGINAL_AREAS" --arg check "$TABLE_CHECK" '
        .track == "code" and
        (.agents | sort) == ($areas + ["spec"] | sort) and
        .skipped_agents == [] and
        .agent_decisions.spec.evidence[0].check == $check and
        (.agent_decisions.spec.evidence[0].result | contains("docs/guide.md"))
    '
}

@test "a code-only PR takes the code track and skips spec with table evidence" {
    modify_hunk src/app.py | use_patch

    classify

    assert_complete_decisions
    assert_every_skip_has_evidence
    assert_json --argjson areas "$ORIGINAL_AREAS" --arg check "$TABLE_CHECK" '
        .track == "code" and
        (.agents | sort) == ($areas | sort) and
        .skipped_agents == ["spec"] and
        .agent_decisions.spec.evidence == [{check: $check, result: "No changed path is spec content"}]
    '
}

@test "agent prompts and instruction files take the code track with spec skipped" {
    for path in agents/code-reviewer-security.md skills/review-code/handlers/review.md \
        .github/PULL_REQUEST_TEMPLATE.md .claude/commands/x.md SKILL.md docs/AGENTS.md; do
        modify_hunk "$path" | use_patch
        echo "path: $path"
        classify
        assert_code_track_full_review
        assert_json '.agent_decisions.spec.decision == "skip"'
    done
}

@test "explorer spec applies does not run spec on a code PR" {
    modify_hunk src/app.py | use_patch
    write_routing '{"scope":"full","areas":{"spec":{"status":"applies"}}}'

    classify --explorer-context "$CONTEXT"

    assert_json '.track == "code" and .agent_decisions.spec.decision == "skip"'
}

@test "explorer spec negative evidence does not skip spec on a Markdown PR" {
    modify_hunk docs/guide.md | use_patch
    write_routing "$(negative_evidence_for spec)"

    classify --explorer-context "$CONTEXT"

    assert_spec_track
    assert_json '.agent_decisions.spec.decision == "run"'
}

@test "explorer negative evidence still skips maintainability on the spec track" {
    modify_hunk docs/guide.md | use_patch
    write_routing "$(negative_evidence_for maintainability)"

    classify --explorer-context "$CONTEXT"

    assert_complete_decisions
    assert_json '
        .track == "spec" and
        (.agents | sort) == ["compatibility", "correctness", "spec"] and
        .agent_decisions.maintainability.decision == "skip" and
        .agent_decisions.maintainability.evidence[0].result == "Nothing in this area changed."
    '
}

@test "explorer applies for testing does not run testing on the spec track" {
    modify_hunk docs/guide.md | use_patch
    write_routing '{"scope":"full","areas":{"testing":{"status":"applies"}}}'

    classify --explorer-context "$CONTEXT"

    assert_spec_track
    assert_json --arg check "$TABLE_CHECK" '
        .agent_decisions.testing.decision == "skip" and
        .agent_decisions.testing.evidence[0].check == $check
    '
}

@test "an area override on a spec-only PR selects exactly that area and reports the code track" {
    use_patch < "$FIXTURE"

    classify --area security

    assert_complete_decisions
    assert_json '.track == "code" and (.agents | sort) == ["correctness", "security"]'
}

@test "caller reviewers on a spec-only PR select exactly those reviewers and report the code track" {
    use_patch < "$FIXTURE"
    change_session '.reviewers = ["testing"]'

    classify

    assert_complete_decisions
    assert_json '.track == "code" and .agents == ["correctness", "testing"]'
}

@test "caller reviewers can select the spec reviewer" {
    use_patch < "$FIXTURE"
    change_session '.reviewers = ["spec"]'

    classify

    assert_json '.track == "code" and .agents == ["correctness", "spec"]'
}

@test "briefing on a spec-only PR writes a spec diff equal to the full diff" {
    use_patch < "$FIXTURE"

    run "$SCRIPTS/build-agent-briefing.sh" "$SESSION" --agents "correctness spec compatibility maintainability"

    [ "$status" -eq 0 ]
    cmp "$ARTIFACTS/diff.patch" "$ARTIFACTS/diff-spec.patch"
    lines=$(wc -l < "$ARTIFACTS/diff-spec.patch" | tr -d ' ')
    assert_json --argjson lines "$lines" '.scoped_diffs["diff-spec.patch"] == $lines'
}

@test "briefing on a mixed PR writes only the Markdown hunk and names the code file" {
    { modify_hunk src/app.py 'python_value = 2' 'python_value = 1'; modify_hunk docs/guide.md; } | use_patch

    run "$SCRIPTS/build-agent-briefing.sh" "$SESSION" --agents "correctness spec"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^diff --git' "$ARTIFACTS/diff-spec.patch")" -eq 1 ]
    grep -q '^diff --git a/docs/guide.md b/docs/guide.md$' "$ARTIFACTS/diff-spec.patch"
    ! grep -q 'python_value' "$ARTIFACTS/diff-spec.patch"
    grep -q 'Other files changed' "$ARTIFACTS/diff-spec.patch"
    grep -q 'src/app.py' "$ARTIFACTS/diff-spec.patch"
    assert_json '.scoped_diffs["diff-spec.patch"] > 0'
}

@test "briefing with no spec paths removes a stale spec diff and leaves it out of scoped_diffs" {
    modify_hunk src/app.py | use_patch
    printf 'stale\n' > "$ARTIFACTS/diff-spec.patch"

    run "$SCRIPTS/build-agent-briefing.sh" "$SESSION" --agents "correctness spec"

    [ "$status" -eq 0 ]
    [ ! -e "$ARTIFACTS/diff-spec.patch" ]
    assert_json '.scoped_diffs | has("diff-spec.patch") | not'
}

@test "spec agent carries the shared reviewer blocks" {
    [ -f "$SPEC_AGENT" ]
    frontmatter=$(awk 'NR == 1 && /^---$/ { inside = 1; next } inside && /^---$/ { exit } inside' "$SPEC_AGENT")
    grep -q '^name: code-reviewer-spec$' <<< "$frontmatter"
    grep -q '^model: opus$' <<< "$frontmatter"
    grep -q 'execution-tier: deep' <<< "$frontmatter"
    grep -q '^## Before You Review' "$SPEC_AGENT"
    grep -q '^## Self-Challenge' "$SPEC_AGENT"
    grep -q 'Confidence Scoring Guidelines' "$SPEC_AGENT"
    grep -q '90-100%' "$SPEC_AGENT"
    grep -q 'not spec content, even when they are Markdown' "$SPEC_AGENT"
}

extract_example_finding() {
    python3 - "$SPEC_AGENT" <<'PY'
import re
import sys

lines = open(sys.argv[1]).read().splitlines()
for start, line in enumerate(lines):
    if not re.fullmatch(r"`{3,}text", line.strip()):
        continue
    depth, end = 1, start + 1
    while end < len(lines) and depth:
        stripped = lines[end].strip()
        if re.fullmatch(r"`{3,}[^`\s].*", stripped):
            depth += 1
        elif re.fullmatch(r"```+", stripped):
            depth -= 1
        end += 1
    trailer = end
    while trailer < len(lines) and not lines[trailer].strip():
        trailer += 1
    if depth == 0 and trailer < len(lines) and re.match(r"^Location: .+ \| Confidence: \d+%$", lines[trailer]):
        print("\n".join(lines[start : trailer + 1]))
        sys.exit(0)
sys.exit(1)
PY
}

@test "spec agent example is a text-fenced finding followed by a Location trailer that parses as a spec finding" {
    run extract_example_finding
    [ "$status" -eq 0 ]
    example="$output"
    confidence=$(tail -1 <<< "$example" | sed -E 's/.*Confidence: ([0-9]+)%.*/\1/')
    printf '## Spec Review\n\n### 1. Example\n\n%s\n' "$example" > "$BATS_TEST_TMPDIR/review.md"

    run "$SCRIPTS/parse-review-findings.sh" "$BATS_TEST_TMPDIR/review.md"

    [ "$status" -eq 0 ]
    assert_json --argjson confidence "$confidence" 'length == 1 and .[0].agent == "spec" and .[0].confidence == $confidence'
}

@test "spec-content twins of the guard cases take the spec track" {
    modify_hunk docs/a.md | use_patch
    classify
    assert_spec_track

    printf '%s\n' 'diff --git a/docs/old.md b/docs/eval.md' 'similarity index 90%' \
        'rename from docs/old.md' 'rename to docs/eval.md' 'index 1111111..2222222 100644' \
        '--- a/docs/old.md' '+++ b/docs/eval.md' '@@ -1 +1 @@' '-old' '+new' | use_patch
    classify
    assert_spec_track

    { delete_hunk docs/old.md; add_hunk docs/new.md; } | use_patch
    classify
    assert_spec_track
}

@test "a rename from a code file to a Markdown path takes the code track" {
    guard_case 'diff --git a/src/eval.py b/docs/eval.md
similarity index 90%
rename from src/eval.py
rename to docs/eval.md
index 1111111..2222222 100644
--- a/src/eval.py
+++ b/docs/eval.md
@@ -1 +1 @@
-old
+new
'
}

@test "a pure rename from a code file to a Markdown path takes the code track" {
    guard_case 'diff --git a/src/eval.py b/docs/eval.md
similarity index 100%
rename from src/eval.py
rename to docs/eval.md
'
}

@test "a rename from an agent prompt to a docs Markdown path takes the code track" {
    guard_case 'diff --git a/agents/code-reviewer-security.md b/docs/security-review.md
similarity index 100%
rename from agents/code-reviewer-security.md
rename to docs/security-review.md
'
}

@test "a copy from a code file to a Markdown path takes the code track" {
    guard_case 'diff --git a/src/a.py b/docs/a-copy.md
similarity index 100%
copy from src/a.py
copy to docs/a-copy.md
'
}

@test "a quoted rename-from path takes the code track whatever it decodes to" {
    for old in 'src/caf\303\251.py' 'docs/caf\303\251.md'; do
        echo "old path: $old"
        guard_case "diff --git \"a/$old\" b/docs/cafe.md
similarity index 100%
rename from \"$old\"
rename to docs/cafe.md
"
    done
}

@test "a mode-only change on a Markdown path takes the code track" {
    guard_case 'diff --git a/docs/run.md b/docs/run.md
old mode 100644
new mode 100755
'
}

@test "a new executable file with a Markdown name takes the code track" {
    guard_case 'diff --git a/docs/run.md b/docs/run.md
new file mode 100755
index 0000000..2222222
--- /dev/null
+++ b/docs/run.md
@@ -0,0 +1 @@
+#!/bin/sh
'
}

@test "a new symlink with a Markdown name takes the code track" {
    guard_case 'diff --git a/docs/link.md b/docs/link.md
new file mode 120000
index 0000000..1234567
--- /dev/null
+++ b/docs/link.md
@@ -0,0 +1 @@
+../src/app.py
\ No newline at end of file
'
}

@test "a submodule bump with a Markdown name takes the code track" {
    guard_case 'diff --git a/docs/vendor.md b/docs/vendor.md
index 1111111..2222222 160000
--- a/docs/vendor.md
+++ b/docs/vendor.md
@@ -1 +1 @@
-Subproject commit 1111111111111111111111111111111111111111
+Subproject commit 2222222222222222222222222222222222222222
'
}

@test "a binary image takes the code track" {
    guard_case 'diff --git a/docs/diagram.png b/docs/diagram.png
index 1111111..2222222 100644
Binary files a/docs/diagram.png and b/docs/diagram.png differ
'
}

@test "binary content on a Markdown path takes the code track" {
    guard_case 'diff --git a/docs/blob.md b/docs/blob.md
index 1111111..2222222 100644
Binary files a/docs/blob.md and b/docs/blob.md differ
'
    guard_case 'diff --git a/docs/blob.md b/docs/blob.md
index 1111111..2222222 100644
GIT binary patch
literal 4
LcmZQzWMTjS00RI3

literal 0
HcmV?d00001

'
}

@test "a deleted code file beside an added Markdown file takes the code track" {
    { delete_hunk src/old.py; add_hunk docs/new.md; } | use_patch

    classify

    assert_code_track_full_review
}

@test "an empty whole-review file list takes the code track" {
    modify_hunk docs/a.md | use_patch
    change_session '.file_metadata.modified_files = [] | .file_metadata.file_count = 0'

    classify

    assert_code_track_full_review
}

@test "an empty reviewed patch takes the code track" {
    modify_hunk docs/a.md | use_patch
    : > "$BATS_TEST_TMPDIR/empty.patch"

    classify --diff-file "$BATS_TEST_TMPDIR/empty.patch"

    assert_json '.track == "code"'
}

@test "a spec path flagged as infra config takes the code track" {
    modify_hunk docs/a.md | use_patch
    change_session '.file_metadata.modified_files[0].is_infra_config = true'

    classify

    assert_json '.track == "code"'
}

@test "a session without diff_path takes the code track" {
    modify_hunk docs/a.md | use_patch
    change_session 'del(.diff_path)'

    classify

    assert_code_track_full_review
}

@test "a session whose diff_path is unreadable takes the code track" {
    modify_hunk docs/a.md | use_patch
    for target in "$BATS_TEST_TMPDIR/missing.patch" "$ARTIFACTS"; do
        change_session --arg path "$target" '.diff_path = $path'
        echo "diff_path: $target"
        classify
        assert_code_track_full_review
    done
}

@test "a patch blocker in the reviewed delta takes the code track" {
    modify_hunk docs/a.md | use_patch
    printf '%s\n' 'diff --git a/src/eval.py b/docs/eval.md' 'similarity index 100%' \
        'rename from src/eval.py' 'rename to docs/eval.md' > "$BATS_TEST_TMPDIR/delta.patch"

    classify --diff-file "$BATS_TEST_TMPDIR/delta.patch"

    assert_json '.track == "code" and .agent_decisions.security.decision == "run"'
}

@test "a Markdown-only chunk of a mixed PR stays on the code track" {
    { modify_hunk src/app.py; modify_hunk docs/guide.md; } | use_patch
    modify_hunk docs/guide.md > "$BATS_TEST_TMPDIR/chunk.patch"

    classify --diff-file "$BATS_TEST_TMPDIR/chunk.patch"

    assert_json '
        .track == "code" and
        .agent_decisions.correctness.decision == "run" and
        .agent_decisions.security.decision == "run"
    '
}

@test "a Markdown-only delta on a code PR stays on the code track" {
    { modify_hunk src/app.py; modify_hunk docs/guide.md; } | use_patch
    modify_hunk docs/guide.md 'newer value' 'new value' > "$BATS_TEST_TMPDIR/delta.patch"

    classify --diff-file "$BATS_TEST_TMPDIR/delta.patch"

    assert_json '.track == "code"'
}

@test "a spec-only delta on a spec-only PR takes the spec track" {
    use_patch < "$FIXTURE"
    modify_hunk openspec/specs/local-feature-flag-evaluator/spec.md 'newer value' 'new value' > "$BATS_TEST_TMPDIR/delta.patch"

    classify --diff-file "$BATS_TEST_TMPDIR/delta.patch"

    assert_spec_track
}

@test "the pre-exploration and post-exploration calls reach the same track" {
    routing=$(jq -nc --argjson areas "$ALL_AREAS" '{scope: "full", areas: ($areas | map({key: ., value: {status: "not_applicable", evidence: [{check: "Read every changed file", result: "Nothing in this area changed."}]}}) | from_entries)}')
    write_routing "$routing"

    use_patch < "$FIXTURE"
    classify
    assert_json '.track == "spec"'
    classify --explorer-context "$CONTEXT"
    assert_json '.track == "spec"'

    { modify_hunk src/app.py; modify_hunk docs/guide.md; } | use_patch
    classify
    assert_json '.track == "code"'
    classify --explorer-context "$CONTEXT"
    assert_json '.track == "code"'
}

# Builds a two-chunk session. The whole-review diff is the two chunk patches
# joined, and each chunk has a readable analysis with an empty routing block.
use_chunks() {
    local first="$1" second="$2"
    cat "$first" "$second" | use_patch
    printf 'architecture\n' > "$ARTIFACTS/architectural-context.md"
    cp "$first" "$ARTIFACTS/first.patch"
    cp "$second" "$ARTIFACTS/second.patch"
    change_session '.chunks = [
        {id: "first", label: "First", files: ["first"], diff_path: (.artifacts_dir + "/first.patch")},
        {id: "second", label: "Second", files: ["second"], diff_path: (.artifacts_dir + "/second.patch")}
    ]'
    for index in 0 1; do
        printf '```review-routing\n{"scope":"full","areas":{}}\n```\n' > "$ARTIFACTS/chunk-$index-analysis.md"
    done
}

@test "chunk classifications of a mixed PR all report the code track" {
    modify_hunk docs/guide.md > "$BATS_TEST_TMPDIR/prose.patch"
    modify_hunk src/app.py > "$BATS_TEST_TMPDIR/code.patch"
    use_chunks "$BATS_TEST_TMPDIR/prose.patch" "$BATS_TEST_TMPDIR/code.patch"

    run python3 "$SCRIPTS/prepare-chunk-artifacts.py" "$SESSION" --classify

    [ "$status" -eq 0 ]
    assert_json 'all(.chunks[]; .classification.track == "code")'
    jq -e '.track == "code" and all(.chunks[]; .classification.track == "code")' "$ARTIFACTS/review-routing.json"
    jq -e '.track == "code"' "$ARTIFACTS/chunk-0-routing.json"
}

@test "chunk classifications of a spec-only PR all report the spec track" {
    modify_hunk docs/guide.md > "$BATS_TEST_TMPDIR/prose.patch"
    modify_hunk acceptance/private/flags.feature > "$BATS_TEST_TMPDIR/scenarios.patch"
    use_chunks "$BATS_TEST_TMPDIR/prose.patch" "$BATS_TEST_TMPDIR/scenarios.patch"

    run python3 "$SCRIPTS/prepare-chunk-artifacts.py" "$SESSION" --classify

    [ "$status" -eq 0 ]
    jq -e '.track == "spec" and all(.chunks[]; .classification.track == "spec")' "$ARTIFACTS/review-routing.json"
}

# Copies prepare-chunk-artifacts.py beside a classifier wrapper. The wrapper
# runs the real classifier and, when FLIP_TRACK is 1, changes only the first
# call's track.
make_flipping_classifier() {
    STUB_DIR="$BATS_TEST_TMPDIR/stub-scripts"
    mkdir -p "$STUB_DIR"
    cp "$SCRIPTS/prepare-chunk-artifacts.py" "$STUB_DIR/"
    ln -s "$SCRIPTS/pre-review-context.sh" "$STUB_DIR/pre-review-context.sh"
    ln -s "$SCRIPTS/helpers" "$STUB_DIR/helpers"
    cat > "$STUB_DIR/classify-review-scope.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
counter="$BATS_TEST_TMPDIR/classify-calls"
calls=\$(( \$(cat "\$counter" 2>/dev/null || echo 0) + 1 ))
echo "\$calls" > "\$counter"
result=\$("$CLASSIFY" "\$@")
if [ "\$calls" -eq 1 ] && [ "\${FLIP_TRACK:-0}" = 1 ]; then
    jq -c '.track = (if .track == "spec" then "code" else "spec" end)' <<< "\$result"
else
    printf '%s\n' "\$result"
fi
STUB
    chmod +x "$STUB_DIR/classify-review-scope.sh"
}

@test "chunk aggregation carries the shared track and fails when chunks disagree" {
    modify_hunk docs/guide.md > "$BATS_TEST_TMPDIR/prose.patch"
    modify_hunk acceptance/private/flags.feature > "$BATS_TEST_TMPDIR/scenarios.patch"
    use_chunks "$BATS_TEST_TMPDIR/prose.patch" "$BATS_TEST_TMPDIR/scenarios.patch"
    make_flipping_classifier

    export FLIP_TRACK=0
    run python3 "$STUB_DIR/prepare-chunk-artifacts.py" "$SESSION" --classify
    [ "$status" -eq 0 ]
    jq -e '.track == "spec" and all(.chunks[]; .classification.track == "spec")' "$ARTIFACTS/review-routing.json"

    rm -f "$BATS_TEST_TMPDIR/classify-calls" "$ARTIFACTS/review-routing.json"
    export FLIP_TRACK=1
    run python3 "$STUB_DIR/prepare-chunk-artifacts.py" "$SESSION" --classify
    unset FLIP_TRACK
    [ "$status" -ne 0 ]
    [[ "$output" == *track* ]]
}

assert_security_runs_for() {
    local term="$1"
    assert_json --arg term "$term" '
        .track == "spec" and
        .agent_decisions.security.decision == "run" and
        (.agent_decisions.security.reason | ascii_downcase | contains($term))
    '
}

assert_security_skipped_on_spec_track() {
    assert_json --arg check "$TABLE_CHECK" '
        .track == "spec" and
        .agent_decisions.security.decision == "skip" and
        .agent_decisions.security.evidence[0].check == $check
    '
}

@test "a spec requiring the personal API key in the Authorization header runs security and names the terms" {
    modify_hunk openspec/specs/flags/spec.md 'The SDK MUST send the personal API key in the Authorization header.' | use_patch

    classify

    assert_security_runs_for "api key"
    assert_json '.agent_decisions.security.reason | ascii_downcase | contains("authoriz")'
}

@test "each security term class in a changed spec line runs security" {
    cases=(
        'credential|The SDK MUST NOT log credentials.'
        'access token|The SDK MUST refresh the access token before it expires.'
        'email address|Events MUST NOT include the email address of the user.'
        'redact|The SDK MUST redact property values before sending them.'
        'cookie|The SDK MUST NOT set a cookie before the visitor opts in.'
        'consent|The SDK MUST wait for consent before capturing events.'
    )
    for case in "${cases[@]}"; do
        term="${case%%|*}"
        line="${case#*|}"
        echo "term: $term"
        modify_hunk openspec/specs/flags/spec.md "$line" | use_patch
        classify
        assert_security_runs_for "$term"
    done
}

@test "a security term in a changed path runs security" {
    modify_hunk openspec/specs/authentication/spec.md 'Flags load lazily.' 'Flags load at startup.' | use_patch

    classify

    assert_security_runs_for "authenticat"
}

@test "a security term only in a rename-from path runs security" {
    printf '%s\n' 'diff --git a/openspec/specs/authentication/spec.md b/openspec/specs/login/spec.md' \
        'similarity index 100%' 'rename from openspec/specs/authentication/spec.md' \
        'rename to openspec/specs/login/spec.md' | use_patch

    classify

    assert_security_runs_for "authenticat"
}

@test "a bare token in a changed spec line runs security" {
    modify_hunk openspec/specs/flags/spec.md 'The SDK MUST send the project token with every request.' | use_patch

    classify

    assert_security_runs_for "token"
}

@test "the test-token initialization step in a feature file does not run security" {
    modify_hunk acceptance/private/flags.feature \
        '    Given the SDK is initialized with token "test-token" and local evaluation enabled' \
        '    Given the SDK is initialized with local evaluation enabled' | use_patch

    classify

    assert_security_skipped_on_spec_track
}

@test "a qualified token term in a feature file runs security" {
    modify_hunk acceptance/private/flags.feature \
        '    Given the SDK is initialized with an expired access token' | use_patch

    classify

    assert_security_runs_for "access token"
}

@test "a security term only in a context line does not run security" {
    printf '%s\n' 'diff --git a/docs/guide.md b/docs/guide.md' 'index 1111111..2222222 100644' \
        '--- a/docs/guide.md' '+++ b/docs/guide.md' '@@ -1,3 +1,3 @@' \
        ' The SDK MUST send the password over TLS.' '-Flags load at startup.' '+Flags load lazily.' ' Done.' | use_patch

    classify

    assert_security_skipped_on_spec_track
}

@test "explorer security applies runs security on the spec track without a term" {
    modify_hunk docs/guide.md 'Flags load lazily.' | use_patch
    write_routing '{"scope":"full","areas":{"security":{"status":"applies"}}}'

    classify --explorer-context "$CONTEXT"

    assert_json '.track == "spec" and .agent_decisions.security.decision == "run"'
}

@test "explorer security uncertain does not run security on the spec track without a term" {
    modify_hunk docs/guide.md 'Flags load lazily.' | use_patch
    write_routing '{"scope":"full","areas":{"security":{"status":"uncertain"}}}'

    classify --explorer-context "$CONTEXT"

    assert_security_skipped_on_spec_track
}

# run-eval.sh commits base.patch and diff.patch on one branch, so the review
# sees the combined diff from the commit before base.patch.
@test "the spec-requirement-gaps benchmark takes the spec track with security skipped" {
    local bench="$PROJECT_ROOT/evals/benchmarks/crafted/spec-requirement-gaps"
    local repo="$BATS_TEST_TMPDIR/benchmark-repo"
    local git_cmd=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$repo"
        -c user.name=eval -c user.email=eval@example.com -c commit.gpgsign=false)
    mkdir -p "$repo"
    "${git_cmd[@]}" init -q
    "${git_cmd[@]}" commit -q --allow-empty -m initial
    local initial
    initial=$("${git_cmd[@]}" rev-parse HEAD)
    local patch
    for patch in base.patch diff.patch; do
        "${git_cmd[@]}" apply "$bench/$patch"
        "${git_cmd[@]}" add -A
        "${git_cmd[@]}" commit -q -m "$patch"
    done

    "${git_cmd[@]}" diff --no-ext-diff --no-color "$initial" HEAD | use_patch

    classify

    assert_spec_track
    assert_security_skipped_on_spec_track
}
