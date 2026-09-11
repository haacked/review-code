#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/review-dispatch-plan.py"
    FIELDS="$BATS_TEST_TMPDIR/fields.json"
    printf '%s\n' '{}' > "$FIELDS"
}

@test "unchunked review maps all nine areas in order and removes duplicates" {
    printf '%s\n' '{"chunk_metadata":{"chunked":false}}' > "$FIELDS"
    run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security correctness performance architecture maintainability compatibility testing frontend infra-config security'
    [ "$status" -eq 0 ]
    expected='{"handler":null,"agents":[{"area":"security","subagent_type":"code-reviewer-security"},{"area":"correctness","subagent_type":"code-reviewer-correctness"},{"area":"performance","subagent_type":"code-reviewer-performance"},{"area":"architecture","subagent_type":"code-reviewer-architecture"},{"area":"maintainability","subagent_type":"code-reviewer-maintainability"},{"area":"compatibility","subagent_type":"code-reviewer-compatibility"},{"area":"testing","subagent_type":"code-reviewer-testing"},{"area":"frontend","subagent_type":"code-reviewer-frontend"},{"area":"infra-config","subagent_type":"code-reviewer-infra-config"}]}'
    [ "$(printf '%s' "$output" | jq -cS .)" = "$(printf '%s' "$expected" | jq -cS .)" ]
}

@test "missing chunk metadata selects ordinary dispatch" {
    run python3 "$SCRIPT" --fields "$FIELDS" --agents 'correctness'
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .)" = '{"handler":null,"agents":[{"area":"correctness","subagent_type":"code-reviewer-correctness"}]}' ]
}

@test "chunked review selects its handler without ordinary agent invocations" {
    printf '%s\n' '{"chunk_metadata":{"chunked":true,"chunk_count":2},"chunks":[{"id":1,"label":"backend","files":["a.py"],"diff_path":"one.patch"},{"id":2,"label":"frontend","files":["b.ts"],"diff_path":"two.patch"}]}' > "$FIELDS"
    run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security correctness'
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .)" = '{"handler":"review-chunked.md","agents":[]}' ]
}

@test "delta review ignores full-review chunks" {
    printf '%s\n' '{"chunk_metadata":{"chunked":true,"chunk_count":1},"chunks":[{"id":1,"label":"full review","files":["a.py"],"diff_path":"full.patch"}]}' > "$FIELDS"
    run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security correctness' --review-mode delta
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .)" = '{"handler":null,"agents":[{"area":"security","subagent_type":"code-reviewer-security"},{"area":"correctness","subagent_type":"code-reviewer-correctness"}]}' ]
}

@test "unknown areas cannot become dispatch invocations" {
    run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security unknown'
    [ "$status" -ne 0 ]
}

@test "empty agent selection is rejected" {
    run python3 "$SCRIPT" --fields "$FIELDS" --agents ''
    [ "$status" -ne 0 ]
}

@test "malformed review fields are rejected" {
    printf '%s\n' '{' > "$FIELDS"
    run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security'
    [ "$status" -ne 0 ]
}

@test "chunked must be a boolean" {
    printf '%s\n' '{"chunk_metadata":{"chunked":"true"}}' > "$FIELDS"
    run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security'
    [ "$status" -ne 0 ]
}

@test "chunk metadata must be an object" {
    for metadata in '[]' '""' '0'; do
        jq -n --argjson metadata "$metadata" '{chunk_metadata:$metadata}' > "$FIELDS"
        run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security'
        [ "$status" -ne 0 ]
    done
}

@test "chunked dispatch rejects missing or empty chunks" {
    for fields in \
        '{"chunk_metadata":{"chunked":true,"chunk_count":1}}' \
        '{"chunk_metadata":{"chunked":true,"chunk_count":1},"chunks":[]}'; do
        printf '%s\n' "$fields" > "$FIELDS"
        run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security'
        [ "$status" -ne 0 ]
    done
}

@test "chunked dispatch requires a positive count matching the chunks" {
    for metadata in \
        '{"chunked":true}' \
        '{"chunked":true,"chunk_count":0}' \
        '{"chunked":true,"chunk_count":-1}' \
        '{"chunked":true,"chunk_count":2}'; do
        jq -n --argjson metadata "$metadata" '{chunk_metadata:$metadata,chunks:[{id:1,diff_path:"one.patch"}]}' > "$FIELDS"
        run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security'
        [ "$status" -ne 0 ]
    done
}

@test "chunked dispatch rejects malformed chunk records" {
    for chunk in \
        '{}' \
        '{"id":1,"label":"backend","files":["a.py"]}' \
        '{"id":1,"label":"backend","files":["a.py"],"diff_path":""}' \
        '{"id":1,"label":"","files":["a.py"],"diff_path":"one.patch"}' \
        '{"id":1,"label":"backend","files":[],"diff_path":"one.patch"}'; do
        jq -n --argjson chunk "$chunk" '{chunk_metadata:{chunked:true,chunk_count:1},chunks:[$chunk]}' > "$FIELDS"
        run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security'
        [ "$status" -ne 0 ]
    done
}

@test "chunked dispatch requires sequential chunk IDs" {
    for ids in '[1,1]' '[0,1]' '[2,1]'; do
        jq -n --argjson ids "$ids" '{chunk_metadata:{chunked:true,chunk_count:2},chunks:[$ids[] | {id:.,label:"chunk",files:["a.py"],diff_path:"one.patch"}]}' > "$FIELDS"
        run python3 "$SCRIPT" --fields "$FIELDS" --agents 'security'
        [ "$status" -ne 0 ]
    done
}

@test "review handler chooses routing before specialized dispatch" {
    run python3 - "$PROJECT_ROOT/skills/review-code/handlers/review.md" <<'PY'
import pathlib
import sys

review = pathlib.Path(sys.argv[1]).read_text()
assert review.index("### Choose Review Dispatch") < review.index("### Invoke Specialized Review Agents")
assert "review-chunked.md" in review[review.index("### Choose Review Dispatch"):review.index("### Invoke Specialized Review Agents")]
assert '--review-mode "<$review_mode, default full>"' in review
PY
    [ "$status" -eq 0 ]
}

@test "review handler defers synthesis and validation in order" {
    run python3 - "$PROJECT_ROOT/skills/review-code/handlers/review.md" <<'PY'
import pathlib
import sys

review = pathlib.Path(sys.argv[1]).read_text()
dispatch = review.index("### Invoke Specialized Review Agents")
coverage = review.index("### Check What Each Agent Actually Read")
synthesis = review.index("review-synthesis.md")
validation = review.index("review-validation.md")
quality = review.index("### Finding Quality Pipeline")
assert dispatch < coverage < synthesis < validation < quality
PY
    [ "$status" -eq 0 ]
}

@test "PR output and fix procedures load only at their stages" {
    run python3 - "$PROJECT_ROOT/skills/review-code/handlers/review.md" <<'PY'
import pathlib
import sys

review = pathlib.Path(sys.argv[1]).read_text()
early = review[review.index("### Load Conditional Instructions"):review.index("### Decide Whether This Is a Re-review")]
assert "review-pr-output.md" not in early
assert "review-fix.md" not in early
quality_stage = review.index("### Finding Quality Pipeline")
assert review.index("review-pr-output.md", quality_stage) < review.index("review-finding-quality.md", quality_stage)
assert review.index("review-finding-quality.md", quality_stage) < review.index("review-fix.md", quality_stage)
fix_stage = review[review.index("### Apply Fixes (--fix flag)"):review.index("### Compose the Review Document")]
assert 'If `REVIEW_FIELDS.fix` is true' in fix_stage
assert "review-fix.md" in fix_stage
PY
    [ "$status" -eq 0 ]
}

@test "deferred handlers retain synthesis and validation safeguards" {
    run python3 - "$PROJECT_ROOT/skills/review-code/handlers" <<'PY'
import pathlib
import sys

handlers = pathlib.Path(sys.argv[1])
synthesis = (handlers / "review-synthesis.md").read_text()
validation = (handlers / "review-validation.md").read_text()
for required in ("IN_SCOPE_PATHS", "No ask", "Solo finding, confidence >= 40%", "Comment Body Hygiene"):
    assert required in synthesis
for required in ("diff-position-mapper.sh", 'subagent_type` "finding-validator"', "Dispatch all blocking finding validations", "non-blocking findings"):
    assert required in validation
PY
    [ "$status" -eq 0 ]
}
