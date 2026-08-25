#!/usr/bin/env bats
# Tests for amend-pending-review.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/amend-pending-review.sh"
    BLOCKS="$PROJECT_ROOT/skills/review-code/scripts/review-comment-blocks.py"

    TEST_DIR=$(mktemp -d)
    REVIEW="$TEST_DIR/pr-1.md"
    MOCK_DIR="$TEST_DIR/bin"
    mkdir -p "$MOCK_DIR"
    export PATH="$MOCK_DIR:$PATH"
    MUTATIONS="$TEST_DIR/mutations.log"
    : > "$MUTATIONS"
    export MUTATIONS

    write_review
    create_mock_gh
}

teardown() {
    rm -rf "$TEST_DIR"
}

write_review() {
    cat > "$REVIEW" << 'EOF'
<!-- review-metadata
reviewed_at: 2026-08-25T00:00:00Z
mode: pr
pr_number: 1
org: org
repo: test
-->

# Pull Request Review: #1

## Suggested Comments

### New Comments

#### `src/auth.ts:42`

```text
Validate the token first.
```

*From: Security (85% confidence)*

---

#### `src/db.py:12`

```text
N+1 query here.
```

*From: Performance (70% confidence)*

---
EOF
}

# Live pending review with two comments. LIVE_BODY_777 lets a test change what
# GitHub reports without rewriting the mock.
create_mock_gh() {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/usr/bin/env bash
args="$*"
body777="${LIVE_BODY_777:-Validate the token first.}"
[[ -n "${GH_CALL_LOG:-}" ]] && echo "$args" >> "$GH_CALL_LOG"

if [[ "$args" == *"repo view"* ]]; then echo "org/test"; exit 0; fi
if [[ "$args" == *"api user"* ]]; then echo "testuser"; exit 0; fi

if [[ "$args" == *"graphql"* ]]; then
    echo "GRAPHQL $args" >> "$MUTATIONS"
    echo '{"data":{"updatePullRequestReviewComment":{"pullRequestReviewComment":{"databaseId":777}}}}'
    exit 0
fi
if [[ "$args" == *"--method DELETE"* ]]; then
    echo "DELETE $args" >> "$MUTATIONS"; exit 0
fi
if [[ "$args" == *"--method POST"* ]]; then
    echo "POST $args" >> "$MUTATIONS"; exit 0
fi
# Match the real endpoint shapes exactly. A permissive *"/comments"* match
# would answer a malformed URL just as happily as a correct one, which is how
# a missing PR number reached a live run once already.
if [[ "$args" == *"repos/org/test/pulls/1/reviews/99/comments"* ]]; then
    # Comments already deleted this run really are gone, so the mock reads its
    # own mutation log rather than taking a hint from the test. A stateless
    # mock would hide an id before the delete and break membership validation.
    dropped=$(grep -oE 'pulls/comments/[0-9]+' "$MUTATIONS" 2> /dev/null \
        | grep -oE '[0-9]+$' | jq -R -s 'split("\n") | map(select(length > 0) | tonumber)')
    jq -n --arg b "$body777" --argjson dropped "${dropped:-[]}" '[
      {id:777, node_id:"PRRC_aaa", path:"src/auth.ts", line:null, position:3, body:$b},
      {id:888, node_id:"PRRC_bbb", path:"src/db.py", line:null, position:7, body:"N+1 query here."}
    ] | map(select(.id as $i | $dropped | index($i) == null))'
    exit 0
fi
if [[ "$args" == *"repos/org/test/pulls/1/reviews"* ]]; then
    echo '[{"id":99,"state":"PENDING","user":{"login":"testuser"},"body":"summary"}]'
    exit 0
fi
echo "UNEXPECTED-URL $args" >> "$MUTATIONS"
echo '{"message":"Not Found"}'
exit 1
EOF
    chmod +x "$MOCK_DIR/gh"
}

# Record the ids, as a --draft post would.
annotate() {
    jq -n '[
      {id:777, node_id:"PRRC_aaa", path:"src/auth.ts", line:42, body:"Validate the token first."},
      {id:888, node_id:"PRRC_bbb", path:"src/db.py", line:12, body:"N+1 query here."}
    ]' | python3 "$BLOCKS" annotate --review-file "$REVIEW" --review-id 99 > /dev/null
}

# Same shape as tests/unit/test-lint-review-narrative.bats:24.
checksum() {
    md5 -q "$1" 2> /dev/null || md5sum "$1" | cut -d' ' -f1
}

amend() { "$SCRIPT" 1 --review-file "$REVIEW" "$@"; }

# =============================================================================
# Argument validation, before any network call
# =============================================================================

@test "amend: --drop without --comment-id is refused" {
    run amend --drop
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires at least one --comment-id"* ]]
}

@test "amend: --pull and --push cannot be combined" {
    run amend --pull --push
    [ "$status" -eq 1 ]
    [[ "$output" == *"separate runs"* ]]
}

@test "amend: --comment-id must be numeric" {
    run amend --comment-id abc
    [ "$status" -eq 1 ]
    [[ "$output" == *"numeric REST API comment ID"* ]]
}

@test "amend: --help exits zero and describes the script" {
    run amend --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"amend-pending-review.sh"* ]]
}

# =============================================================================
# status
# =============================================================================

@test "amend: status reports both comments in sync and mutates nothing" {
    annotate
    run amend --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.counts.in_sync')" = "2" ]
    [ ! -s "$MUTATIONS" ]
}

@test "amend: status names GitHub as the side that changed" {
    annotate
    LIVE_BODY_777="Edited in the UI." run amend --json
    [ "$(echo "$output" | jq -r '.comments[] | select(.id==777) | .state')" = "changed_on_github" ]
}

@test "amend: status reports position, since a pending comment has no line" {
    annotate
    run amend --json
    [ "$(echo "$output" | jq -r '.comments[] | select(.id==777) | .position')" = "3" ]
}

# =============================================================================
# push
# =============================================================================

@test "amend: push rewords only the comment changed in the notes" {
    annotate
    jq -n '[{id:777, body:"Reworded in the notes."}]' \
        | python3 "$BLOCKS" set-body --review-file "$REVIEW" > /dev/null
    run amend --push
    [ "$status" -eq 0 ]
    [ "$(grep -c GRAPHQL "$MUTATIONS")" -eq 1 ]
    grep -q "PRRC_aaa" "$MUTATIONS"
    ! grep -q "PRRC_bbb" "$MUTATIONS"
}

@test "amend: push refuses when GitHub moved, and names --pull" {
    annotate
    jq -n '[{id:777, body:"Reworded in the notes."}]' \
        | python3 "$BLOCKS" set-body --review-file "$REVIEW" > /dev/null
    LIVE_BODY_777="Edited in the UI." run amend --push
    [ "$status" -eq 1 ]
    [[ "$output" == *"--pull"* ]]
    [ ! -s "$MUTATIONS" ]
}

@test "amend: push with nothing reworded makes no call" {
    annotate
    run amend --push
    [ "$status" -eq 0 ]
    [ ! -s "$MUTATIONS" ]
}

@test "amend: push --dry-run shows the body and calls nothing" {
    annotate
    jq -n '[{id:777, body:"Reworded in the notes."}]' \
        | python3 "$BLOCKS" set-body --review-file "$REVIEW" > /dev/null
    run amend --push --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reworded in the notes."* ]]
    [ ! -s "$MUTATIONS" ]
}

@test "amend: push --comment-id narrows to one comment" {
    annotate
    jq -n '[{id:777, body:"A."},{id:888, body:"B."}]' \
        | python3 "$BLOCKS" set-body --review-file "$REVIEW" > /dev/null
    run amend --push --comment-id 888
    [ "$status" -eq 0 ]
    [ "$(grep -c GRAPHQL "$MUTATIONS")" -eq 1 ]
    grep -q "PRRC_bbb" "$MUTATIONS"
}

# =============================================================================
# pull
# =============================================================================

@test "amend: pull copies the GitHub body into the notes" {
    annotate
    LIVE_BODY_777="Edited in the UI." run amend --pull
    [ "$status" -eq 0 ]
    body=$(python3 "$BLOCKS" read --review-file "$REVIEW" | jq -r '.comments[] | select(.id==777) | .body')
    [ "$body" = "Edited in the UI." ]
}

@test "amend: pull --dry-run leaves the notes alone" {
    annotate
    before=$(checksum "$REVIEW")
    LIVE_BODY_777="Edited in the UI." run amend --pull --dry-run
    [ "$status" -eq 0 ]
    after=$(checksum "$REVIEW")
    [ "$before" = "$after" ]
}

@test "amend: pull then push is allowed, since the notes are current again" {
    annotate
    LIVE_BODY_777="Edited in the UI." amend --pull
    jq -n '[{id:777, body:"Reworded after pulling."}]' \
        | python3 "$BLOCKS" set-body --review-file "$REVIEW" > /dev/null
    LIVE_BODY_777="Edited in the UI." run amend --push
    [ "$status" -eq 0 ]
    [ "$(grep -c GRAPHQL "$MUTATIONS")" -eq 1 ]
}

# =============================================================================
# drop
# =============================================================================

@test "amend: drop deletes exactly the named comment" {
    annotate
    run amend --drop --comment-id 777
    [ "$status" -eq 0 ]
    [ "$(grep -c DELETE "$MUTATIONS")" -eq 1 ]
    grep -q "pulls/comments/777" "$MUTATIONS"
}

@test "amend: drop refuses an id that is not in the pending review" {
    annotate
    run amend --drop --comment-id 4242
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not in your pending review"* ]]
    [ ! -s "$MUTATIONS" ]
}

@test "amend: drop echoes the body before deleting" {
    annotate
    run amend --drop --comment-id 777
    [[ "$output" == *"Validate the token first."* ]]
}

@test "amend: drop --dry-run deletes nothing" {
    annotate
    run amend --drop --comment-id 777 --dry-run
    [ "$status" -eq 0 ]
    [ ! -s "$MUTATIONS" ]
}

# =============================================================================
# It must never be able to submit
# =============================================================================

@test "amend: no mode ever posts a review or an event" {
    annotate
    jq -n '[{id:777, body:"Reworded."}]' \
        | python3 "$BLOCKS" set-body --review-file "$REVIEW" > /dev/null
    amend --json > /dev/null || true
    amend --push || true
    amend --drop --comment-id 888 || true
    ! grep -q "POST" "$MUTATIONS"
    ! grep -q "events" "$MUTATIONS"
}

# =============================================================================
# A drop retires the finding in the notes
# =============================================================================

@test "amend: drop marks the finding withdrawn, with the reason" {
    annotate
    run amend --drop --comment-id 777 --reason "author showed environments are deprecated"
    [ "$status" -eq 0 ]
    grep -q 'withdrawn:' "$REVIEW"
    grep -q '^\*Withdrawn .*author showed environments are deprecated\*$' "$REVIEW"
}

@test "amend: a dropped finding stops being a live finding" {
    PARSER="$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh"
    annotate
    before=$("$PARSER" "$REVIEW" | jq 'length')
    amend --drop --comment-id 777 --reason "not a real issue"
    after=$("$PARSER" "$REVIEW" | jq 'length')
    [ "$after" -eq $((before - 1)) ]
}

@test "amend: a dropped finding keeps its body for the record" {
    annotate
    amend --drop --comment-id 777 --reason "not a real issue"
    grep -q "Validate the token first." "$REVIEW"
}

@test "amend: --dry-run drop marks nothing" {
    annotate
    amend --drop --comment-id 777 --reason "x" --dry-run
    ! grep -q 'withdrawn:' "$REVIEW"
}

@test "amend: --reason is refused outside --drop" {
    run amend --push --reason "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"only applies to --drop"* ]]
}

@test "amend: drop reports how many comments remain" {
    annotate
    run amend --drop --comment-id 777 --reason "x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 comment(s) remain"* ]]
}

@test "amend: every gh call uses a real endpoint shape" {
    annotate
    amend --json > /dev/null
    amend --pull > /dev/null 2>&1 || true
    amend --drop --comment-id 888 --reason "x" > /dev/null 2>&1 || true
    ! grep -q "UNEXPECTED-URL" "$MUTATIONS"
}

# =============================================================================
# Invariants the /simplify pass established
# =============================================================================

# `[[ cond ]] && cmd` as a function's last statement returns 1 when cond is
# false, which under set -euo pipefail kills the run silently after the
# mutation has already landed. Every mode must exit 0 without --json.
@test "amend: every mode exits zero without --json" {
    annotate
    amend > /dev/null
    amend --pull > /dev/null
    amend --push > /dev/null
    jq -n '[{id: 777, body: "Reworded."}]' \
        | python3 "$BLOCKS" set-body --review-file "$REVIEW" > /dev/null
    amend --push > /dev/null
    amend --drop --comment-id 888 --reason "x" > /dev/null
}

@test "amend: a push makes no redundant pending-review lookups" {
    annotate
    jq -n '[{id: 777, body: "Reworded."}]' \
        | python3 "$BLOCKS" set-body --review-file "$REVIEW" > /dev/null
    : > "$TEST_DIR/calls.log"
    GH_CALL_LOG="$TEST_DIR/calls.log" amend --push > /dev/null
    # The reviews list is read once. Re-reading it to recover an id this run
    # already holds is what the refresh path used to do.
    [ "$(grep -c 'reviews --paginate' "$TEST_DIR/calls.log")" -eq 1 ]
}

# emit_json returns without reading stdin when --json is off. Anything piped
# into it takes SIGPIPE, and set -euo pipefail turns that into a silent death
# mid-run. It is a race on the pipe buffer, so only a large payload makes it
# deterministic; a small one hides the bug.
@test "amend: a large payload does not kill a non-JSON run" {
    annotate
    big=$(head -c 200000 /dev/zero | tr '\0' 'x')
    LIVE_BODY_777="$big" run amend --pull --dry-run
    [ "$status" -eq 0 ]
    LIVE_BODY_777="$big" run amend --json
    [ "$status" -eq 0 ]
}
