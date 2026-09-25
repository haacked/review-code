#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPTS="$PROJECT_ROOT/skills/review-code/scripts"
    DIFF="$PROJECT_ROOT/tests/fixtures/diffs/deleted-line-anchors.diff"
    REVIEW="$BATS_TEST_TMPDIR/pr-42.md"
    export ANCHOR_TEST_STATE="$BATS_TEST_TMPDIR/github"
    mkdir -p "$ANCHOR_TEST_STATE" "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    cat > "$BATS_TEST_TMPDIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"api --method POST repos/org/repo/pulls/42/reviews --input -"* ]]; then
    cat > "$ANCHOR_TEST_STATE/payload.json"
    jq '[.comments[0] + {id: 777, node_id: "PRRC_deleted", line: null, original_line: null, position: 1}]' \
        "$ANCHOR_TEST_STATE/payload.json" > "$ANCHOR_TEST_STATE/comments.json"
    echo '{"id":99}'
elif [[ "$*" == *"api repos/org/repo/pulls/42/reviews/99/comments --paginate"* ]]; then
    cat "$ANCHOR_TEST_STATE/comments.json"
elif [[ "$*" == *"api repos/org/repo/pulls/42/reviews --paginate"* ]]; then
    if [[ -f "$ANCHOR_TEST_STATE/payload.json" ]]; then
        echo '[{"id":99,"state":"PENDING","user":{"login":"reviewer"},"body":"Review."}]'
    else
        echo '[]'
    fi
elif [[ "$*" == *"api graphql"* ]]; then
    body="" id=""
    for arg in "$@"; do
        case "$arg" in
            body=*) body="${arg#body=}" ;;
            id=*) id="${arg#id=}" ;;
        esac
    done
    [[ "$id" == PRRC_deleted ]]
    jq --arg body "$body" '.[0].body = $body' "$ANCHOR_TEST_STATE/comments.json" > "$ANCHOR_TEST_STATE/updated.json"
    mv "$ANCHOR_TEST_STATE/updated.json" "$ANCHOR_TEST_STATE/comments.json"
    echo "$id" >> "$ANCHOR_TEST_STATE/amendments"
    echo '{"data":{"updatePullRequestReviewComment":{"pullRequestReviewComment":{"databaseId":777}}}}'
else
    echo "Unexpected GitHub call: $*" >&2
    exit 1
fi
MOCK
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    cat > "$REVIEW" <<'REVIEW'
<!-- review-metadata
mode: pr
pr_number: 42
org: org
repo: repo
-->

# Pull Request Review: #42

## Suggested Comments

### New Comments

#### `src/deleted.py:1`

```text
Keep the required guard.
```

*From: Correctness (95% confidence)*

---
REVIEW
}

@test "deleted file finding posts inline on LEFT and remains amendable by its recorded id" {
    printf '%s\n' '{"targets":[{"path":"src/deleted.py","line":1}]}' \
        | "$SCRIPTS/diff-position-mapper.sh" --diff-file "$DIFF" > "$BATS_TEST_TMPDIR/mappings.json"
    jq -n --arg diff "$DIFF" --arg review "$REVIEW" --slurpfile mapped "$BATS_TEST_TMPDIR/mappings.json" '{
        publication: {
            comments: [{path: "src/deleted.py", line: 1, body: "Keep the required guard."}],
            unmapped_comments: []
        },
        mappings: $mapped[0].mappings,
        context: {
            owner: "org", repo: "repo", pr_number: 42, reviewer_username: "reviewer", summary: "Review.",
            original_diff_path: $diff, review_file: $review
        }
    }' > "$BATS_TEST_TMPDIR/draft-input.json"
    "$SCRIPTS/finding-comment-contract.py" draft "$BATS_TEST_TMPDIR/draft-input.json" > "$BATS_TEST_TMPDIR/draft.json"
    jq -e '.comments[0] | .side == "LEFT" and .line_content == "required_guard()"' "$BATS_TEST_TMPDIR/draft.json"

    run bash -c '"$1/create-draft-review.sh" < "$2"' _ "$SCRIPTS" "$BATS_TEST_TMPDIR/draft.json"

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.success and .inline_count == 1 and .summary_count == 0 and .annotated_count == 1'
    jq -e '.comments == [{path: "src/deleted.py", line: 1, side: "LEFT", body: "Keep the required guard."}]' "$ANCHOR_TEST_STATE/payload.json"
    grep -q '#### `src/deleted.py:1` <!-- pc:777 PRRC_deleted b:' "$REVIEW"

    printf '%s\n' '[{"id":777,"body":"Keep the guard until its replacement is deployed."}]' \
        | "$SCRIPTS/review-comment-blocks.py" set-body --review-file "$REVIEW" > /dev/null
    run "$SCRIPTS/amend-pending-review.sh" https://github.com/org/repo/pull/42 \
        --reviewer reviewer --review-file "$REVIEW" --push

    [ "$status" -eq 0 ]
    [ "$(cat "$ANCHOR_TEST_STATE/amendments")" = "PRRC_deleted" ]
    jq -e '.[0] | .side == "LEFT" and .body == "Keep the guard until its replacement is deployed."' "$ANCHOR_TEST_STATE/comments.json"

    run "$SCRIPTS/amend-pending-review.sh" https://github.com/org/repo/pull/42 \
        --reviewer reviewer --review-file "$REVIEW" --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.counts.in_sync == 1'
}
