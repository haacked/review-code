#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/record-coverage-gaps.py"
    PARSER="$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh"
    REVIEW="$BATS_TEST_TMPDIR/saved review.md"
    COVERAGE="${REVIEW}.artifacts/session-1/coverage"
    mkdir -p "$COVERAGE"
    write_coverage code-reviewer-testing '[]'
    cat > "$REVIEW" << 'EOF'
# Pull Request Review: #1 - Fold constants

## Correctness Review

#### `posthog/hogql/transforms/flag_calls_union.py:320`

```text
`question`: Does this fold match ClickHouse?
```

Location: `posthog/hogql/transforms/flag_calls_union.py:320` | Confidence: 60%
EOF
}

write_coverage() {
    jq -n --argjson gaps "$2" '{files_read: ["a.py"], gaps: $gaps}' > "$COVERAGE/$1.json"
}

record() {
    run python3 "$SCRIPT" --review-file "$REVIEW" --coverage-dir "${1:-$COVERAGE}"
}

@test "record-coverage-gaps: lists every gap verbatim under its reviewer" {
    write_coverage code-reviewer-correctness '["Did not run _fold at flag_calls_union.py:320 against ClickHouse: no services.\nUnverified inputs: NULL IN (1, 2)"]'
    write_coverage code-reviewer-security '["Could not read b.py"]'

    record

    [ "$status" -eq 0 ]
    [ "$(jq -c . <<< "$output")" = '{"count":2}' ]
    grep -Fxq '## Not verified' "$REVIEW"
    grep -Fxq '<!-- coverage-gaps: session-1 -->' "$REVIEW"
    grep -Fxq -- "- \`code-reviewer-correctness\`: Did not run _fold at flag_calls_union.py:320 against ClickHouse: no services. Unverified inputs: NULL IN (1, 2)" "$REVIEW"
    grep -Fxq -- '- `code-reviewer-security`: Could not read b.py' "$REVIEW"
}

@test "record-coverage-gaps: leaves the file untouched when no reviewer has a gap" {
    cp "$REVIEW" "$BATS_TEST_TMPDIR/before.md"

    record

    [ "$status" -eq 0 ]
    [ "$(jq -c . <<< "$output")" = '{"count":0}' ]
    cmp "$BATS_TEST_TMPDIR/before.md" "$REVIEW"
}

@test "record-coverage-gaps: re-running replaces this session's section and keeps an earlier session's" {
    earlier="${REVIEW}.artifacts/session-0/coverage"
    mkdir -p "$earlier"
    jq -n '{files_read: [], gaps: ["Earlier gap"]}' > "$earlier/code-reviewer-correctness.json"
    record "$earlier"
    write_coverage code-reviewer-correctness '["First gap"]'
    record
    write_coverage code-reviewer-correctness '["Second gap"]'

    record

    [ "$status" -eq 0 ]
    [ "$(grep -c '^## Not verified$' "$REVIEW")" -eq 2 ]
    grep -Fq 'Earlier gap' "$REVIEW"
    grep -Fq 'Second gap' "$REVIEW"
    [ "$(grep -c 'First gap' "$REVIEW")" -eq 0 ]

    printf '\n## Lint notes\n\n- keep me\n' >> "$REVIEW"
    write_coverage code-reviewer-correctness '["Third gap"]'
    record

    [ "$status" -eq 0 ]
    grep -Fxq '## Lint notes' "$REVIEW"
    grep -Fxq -- '- keep me' "$REVIEW"
    grep -Fq 'Third gap' "$REVIEW"
    [ "$(grep -c 'Second gap' "$REVIEW")" -eq 0 ]

    write_coverage code-reviewer-correctness '[]'
    record

    [ "$status" -eq 0 ]
    [ "$(grep -c '^## Not verified$' "$REVIEW")" -eq 1 ]
    [ "$(grep -c 'Second gap' "$REVIEW")" -eq 0 ]
    grep -Fq 'Earlier gap' "$REVIEW"
}

@test "record-coverage-gaps: ignores a section quoted inside a fenced block" {
    cat >> "$REVIEW" << 'EOF'

```markdown
## Not verified
<!-- coverage-gaps: session-1 -->
- quoted example
```
EOF
    write_coverage code-reviewer-correctness '["A gap"]'

    record

    [ "$status" -eq 0 ]
    grep -Fq -- '- quoted example' "$REVIEW"
    grep -Fq -- '- `code-reviewer-correctness`: A gap' "$REVIEW"
}

@test "record-coverage-gaps: a gap citing path:line is not parsed as a finding" {
    write_coverage code-reviewer-correctness '["Did not run _fold at posthog/hogql/transforms/flag_calls_union.py:320 against ClickHouse"]'
    record
    [ "$status" -eq 0 ]

    run bash "$PARSER" "$REVIEW"

    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" -eq 1 ]
    [[ "$(jq -r '.[0].description' <<< "$output")" != *"Did not run"* ]]
}

@test "record-coverage-gaps: fails when the coverage directory is missing" {
    record "$BATS_TEST_TMPDIR/missing"

    [ "$status" -ne 0 ]
    [[ "$output" == *"coverage directory not found"* ]]
}
