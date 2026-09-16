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

@test "handler contracts: documented agent-report helper preserves raw findings" {
    cat > "$ARTIFACTS/raw.md" << 'EOF'
#### `src/example.py:42`

```text
`blocking`: Preserve the original `value` and its paragraph breaks.

Use `$value` without expanding it.
```

Location: src/example.py:42 | Confidence: 95%
EOF
    extract_documented_block "$SKILL/handlers/review.md" bash agent-report.sh \
        | sed 's/<agent-name>/correctness/g' > "$ARTIFACTS/agent-report.sh"

    run bash -e "$ARTIFACTS/agent-report.sh" < "$ARTIFACTS/raw.md"

    [ "$status" -eq 0 ]
    cmp "$ARTIFACTS/raw.md" "$ARTIFACTS/findings/correctness.md"
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
