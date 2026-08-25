#!/usr/bin/env bats
# Tests for review-comment-blocks.py

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/review-comment-blocks.py"
    PARSER="$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh"

    TEST_DIR=$(mktemp -d)
    REVIEW="$TEST_DIR/pr-1.md"
    write_review
}

teardown() {
    rm -rf "$TEST_DIR"
}

# A review with two findings. The second body quotes a heading-shaped line, so
# any annotator that does not walk fences will annotate the quote by mistake.
write_review() {
    cat > "$REVIEW" << 'EOF'
<!-- review-metadata
reviewed_at: 2026-08-25T00:00:00Z
mode: pr
pr_number: 1
org: org
repo: test
scope:
  exploration_depth: thorough
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
N+1 query here. The docs show it as:

#### `docs/perf.md:9`

which is the pattern to follow.
```

*From: Performance (70% confidence)*

---
EOF
}

posted_json() {
    jq -n '[
        {id: 777, node_id: "PRRC_aaa", path: "src/auth.ts", line: 42,
         body: "Validate the token first."},
        {id: 888, node_id: "PRRC_bbb", path: "src/db.py", line: 12,
         body: "N+1 query here. The docs show it as:\n\n#### `docs/perf.md:9`\n\nwhich is the pattern to follow."}
    ]'
}

# Same shape as tests/unit/test-lint-review-narrative.bats:24.
checksum() {
    md5 -q "$1" 2> /dev/null || md5sum "$1" | cut -d' ' -f1
}

annotate() {
    posted_json | python3 "$SCRIPT" annotate --review-file "$REVIEW" "$@"
}

# =============================================================================
# Annotation
# =============================================================================

@test "annotate: records id and node_id on each finding heading" {
    run annotate
    [ "$status" -eq 0 ]
    [[ "$output" == *'"annotated": 2'* ]]
    grep -Eq '^#### `src/auth\.ts:42` <!-- pc:777 PRRC_aaa b:[0-9a-f]{8} -->$' "$REVIEW"
    grep -Eq '^#### `src/db\.py:12` <!-- pc:888 PRRC_bbb b:[0-9a-f]{8} -->$' "$REVIEW"
}

@test "annotate: leaves a heading-shaped line inside a fenced body alone" {
    annotate
    grep -q '^#### `docs/perf.md:9`$' "$REVIEW"
    [ "$(grep -c 'pc:' "$REVIEW")" -eq 2 ]
}

@test "annotate: replaces an existing annotation instead of stacking one" {
    annotate
    posted_json | jq '[.[] | .id = (.id + 1) | .node_id = (.node_id + "_v2")]' \
        | python3 "$SCRIPT" annotate --review-file "$REVIEW"
    grep -Eq '^#### `src/auth\.ts:42` <!-- pc:778 PRRC_aaa_v2 b:[0-9a-f]{8} -->$' "$REVIEW"
    run grep -c 'pc:.*pc:' "$REVIEW"
    [ "$output" -eq 0 ]
}

@test "annotate: matches by body when the comment moved to a different line" {
    # Drift remapping posts the comment at line 44 while the heading still says 42.
    jq -n '[{id: 777, node_id: "PRRC_aaa", path: "src/auth.ts", line: 44,
             body: "Validate the token first."}]' \
        | python3 "$SCRIPT" annotate --review-file "$REVIEW"
    grep -Eq '^#### `src/auth\.ts:42` <!-- pc:777 PRRC_aaa b:[0-9a-f]{8} -->$' "$REVIEW"
}

@test "annotate: reports a comment it could not place" {
    run bash -c "jq -n '[{id: 999, node_id: \"PRRC_x\", path: \"src/nope.ts\", line: 1, body: \"orphan\"}]' \
        | python3 '$SCRIPT' annotate --review-file '$REVIEW'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"annotated": 0'* ]]
    [[ "$output" == *'999'* ]]
}

# =============================================================================
# Metadata header
# =============================================================================

@test "annotate: records review_id and posted_at above the nested blocks" {
    annotate --review-id 5023086234 --posted-at 2026-08-25T12:00:00Z
    grep -q '^review_id: 5023086234$' "$REVIEW"
    grep -q '^posted_at: 2026-08-25T12:00:00Z$' "$REVIEW"
    # Both scalars must sit above scope:, not inside it.
    review_line=$(grep -n '^review_id:' "$REVIEW" | cut -d: -f1)
    scope_line=$(grep -n '^scope:' "$REVIEW" | cut -d: -f1)
    [ "$review_line" -lt "$scope_line" ]
}

@test "annotate: rewrites review_id rather than adding a second one" {
    annotate --review-id 111
    annotate --review-id 222
    [ "$(grep -c '^review_id:' "$REVIEW")" -eq 1 ]
    grep -q '^review_id: 222$' "$REVIEW"
}

@test "annotate: only touches the first metadata block" {
    printf '\n<!-- review-metadata\nreviewed_at: 2026-01-01T00:00:00Z\n-->\n' >> "$REVIEW"
    annotate --review-id 111
    [ "$(grep -c '^review_id:' "$REVIEW")" -eq 1 ]
}

# =============================================================================
# The parser must not see any of this
# =============================================================================

@test "annotate: annotations are invisible to parse-review-findings.sh" {
    before=$("$PARSER" "$REVIEW" | jq -S -c '[.[] | {agent, file, line, description}]')
    annotate --review-id 111
    after=$("$PARSER" "$REVIEW" | jq -S -c '[.[] | {agent, file, line, description}]')
    [ "$before" = "$after" ]
}

# =============================================================================
# Fail open
# =============================================================================

@test "annotate: invalid input reports an error and leaves the file untouched" {
    checksum_before=$(checksum "$REVIEW")
    run bash -c "echo 'not json' | python3 '$SCRIPT' annotate --review-file '$REVIEW'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"error":'* ]]
    [[ "$output" != *'"error": null'* ]]
    checksum_after=$(checksum "$REVIEW")
    [ "$checksum_before" = "$checksum_after" ]
}

@test "annotate: a missing review file reports an error rather than failing" {
    run bash -c "jq -n '[]' | python3 '$SCRIPT' annotate --review-file '$TEST_DIR/gone.md'"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"error": null'* ]]
}

# =============================================================================
# read
# =============================================================================

@test "read: returns each recorded block with its ids, path, line and body" {
    annotate --review-id 5023086234
    run bash -c "python3 '$SCRIPT' read --review-file '$REVIEW'"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.comments | length')" -eq 2 ]
    [ "$(echo "$output" | jq -r '.comments[0].id')" = "777" ]
    [ "$(echo "$output" | jq -r '.comments[0].node_id')" = "PRRC_aaa" ]
    [ "$(echo "$output" | jq -r '.comments[0].path')" = "src/auth.ts" ]
    [ "$(echo "$output" | jq -r '.comments[0].line')" = "42" ]
    [ "$(echo "$output" | jq -r '.comments[0].body')" = "Validate the token first." ]
    [ "$(echo "$output" | jq -r '.review_id')" = "5023086234" ]
}

@test "read: skips findings that were never posted" {
    # Nothing annotated yet, so nothing is claimed to exist on GitHub.
    run bash -c "python3 '$SCRIPT' read --review-file '$REVIEW'"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.comments | length')" -eq 0 ]
}

@test "read: keeps a body that contains its own fenced block intact" {
    annotate
    run bash -c "python3 '$SCRIPT' read --review-file '$REVIEW'"
    body=$(echo "$output" | jq -r '.comments[1].body')
    [[ "$body" == *'#### `docs/perf.md:9`'* ]]
    [[ "$body" == *"which is the pattern to follow."* ]]
}

@test "read: fails loud when the review file is missing" {
    run bash -c "python3 '$SCRIPT' read --review-file '$TEST_DIR/gone.md'"
    [ "$status" -eq 1 ]
    [[ "$output" != *'"error": null'* ]]
}

# =============================================================================
# set-body
# =============================================================================

@test "set-body: replaces the named block's body and leaves the others alone" {
    annotate
    run bash -c "jq -n '[{id: 777, body: \"Reworded: check for null first.\"}]' \
        | python3 '$SCRIPT' set-body --review-file '$REVIEW'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"updated": 1'* ]]

    read_out=$(python3 "$SCRIPT" read --review-file "$REVIEW")
    [ "$(echo "$read_out" | jq -r '.comments[0].body')" = "Reworded: check for null first." ]
    [[ "$(echo "$read_out" | jq -r '.comments[1].body')" == *"N+1 query here."* ]]
}

@test "set-body: keeps the heading and its annotation" {
    annotate
    jq -n '[{id: 777, body: "Reworded."}]' | python3 "$SCRIPT" set-body --review-file "$REVIEW"
    grep -Eq '^#### `src/auth\.ts:42` <!-- pc:777 PRRC_aaa b:[0-9a-f]{8} -->$' "$REVIEW"
}

@test "set-body: handles a multi-line replacement body" {
    annotate
    jq -n '[{id: 777, body: "First line.\n\nSecond line."}]' \
        | python3 "$SCRIPT" set-body --review-file "$REVIEW"
    body=$(python3 "$SCRIPT" read --review-file "$REVIEW" | jq -r '.comments[0].body')
    [ "$body" = "First line.

Second line." ]
}

@test "set-body: replacing one body leaves the review parseable and unchanged elsewhere" {
    annotate
    before=$("$PARSER" "$REVIEW" | jq -S -c '[.[] | {agent, file, line}]')
    jq -n '[{id: 777, body: "Reworded."}]' | python3 "$SCRIPT" set-body --review-file "$REVIEW"
    after=$("$PARSER" "$REVIEW" | jq -S -c '[.[] | {agent, file, line}]')
    [ "$before" = "$after" ]
}

@test "set-body: reports ids it could not find" {
    annotate
    run bash -c "jq -n '[{id: 4242, body: \"nope\"}]' \
        | python3 '$SCRIPT' set-body --review-file '$REVIEW'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"updated": 0'* ]]
    [[ "$output" == *'4242'* ]]
}

@test "set-body: fails loud on malformed input" {
    run bash -c "echo 'not json' | python3 '$SCRIPT' set-body --review-file '$REVIEW'"
    [ "$status" -eq 1 ]
    [[ "$output" != *'"error": null'* ]]
}

# =============================================================================
# status
# =============================================================================

# Live pending review matching the fixture as posted.
live_json() {
    jq -n '[
        {id: 777, node_id: "PRRC_aaa", path: "src/auth.ts", position: 3,
         body: "Validate the token first."},
        {id: 888, node_id: "PRRC_bbb", path: "src/db.py", position: 7,
         body: "N+1 query here. The docs show it as:\n\n#### `docs/perf.md:9`\n\nwhich is the pattern to follow."}
    ]'
}

status_of() {
    live_json | jq "$1" | python3 "$SCRIPT" status --review-file "$REVIEW" \
        | jq -r '.comments[] | select(.id == 777) | .state'
}

@test "status: reports in_sync when neither side moved" {
    annotate
    [ "$(status_of '.')" = "in_sync" ]
}

@test "status: names GitHub as the side that changed" {
    annotate
    [ "$(status_of '[.[] | if .id == 777 then .body = "Edited in the GitHub UI." else . end]')" = "changed_on_github" ]
}

@test "status: names the notes as the side that changed" {
    annotate
    jq -n '[{id: 777, body: "Reworded in the notes."}]' \
        | python3 "$SCRIPT" set-body --review-file "$REVIEW"
    [ "$(status_of '.')" = "changed_in_notes" ]
}

@test "status: reports diverged when both sides moved" {
    annotate
    jq -n '[{id: 777, body: "Reworded in the notes."}]' \
        | python3 "$SCRIPT" set-body --review-file "$REVIEW"
    [ "$(status_of '[.[] | if .id == 777 then .body = "Edited in the GitHub UI." else . end]')" = "diverged" ]
}

@test "status: reports a comment that is gone from GitHub" {
    annotate
    [ "$(status_of '[.[] | select(.id != 777)]')" = "missing_on_github" ]
}

@test "status: reports a live comment the notes never recorded" {
    annotate
    run bash -c "live_json_out=\$(jq -n '[{id: 999, path: \"src/other.ts\", body: \"hand written\"}]'); \
        echo \"\$live_json_out\" | python3 '$SCRIPT' status --review-file '$REVIEW'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"unrecorded"'* ]]
    [[ "$output" == *'999'* ]]
}

@test "status: falls back to unknown_baseline without a recorded digest" {
    # An annotation written before digests existed, or hand-edited.
    annotate
    sed -i.bak -E 's/ b:[0-9a-f]{8} -->/ -->/' "$REVIEW"
    [ "$(status_of '[.[] | if .id == 777 then .body = "Edited somewhere." else . end]')" = "unknown_baseline" ]
}

@test "status: counts each state and reports the review id" {
    annotate --review-id 5023086234
    run bash -c "$(declare -f live_json); live_json | python3 '$SCRIPT' status --review-file '$REVIEW'"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.counts.in_sync')" = "2" ]
    [ "$(echo "$output" | jq -r '.review_id')" = "5023086234" ]
}

@test "status: fails loud on a missing review file" {
    run bash -c "jq -n '[]' | python3 '$SCRIPT' status --review-file '$TEST_DIR/gone.md'"
    [ "$status" -eq 1 ]
}

# =============================================================================
# withdraw
# =============================================================================

withdraw() {
    jq -n --arg r "${1:-}" '[{id: 777, reason: $r}]' \
        | python3 "$SCRIPT" withdraw --review-file "$REVIEW" --date 2026-08-25
}

@test "withdraw: stamps the heading and keeps the ids for the record" {
    annotate
    run withdraw "author showed it was already handled"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"withdrawn": 1'* ]]
    grep -Eq '^#### `src/auth\.ts:42` <!-- pc:777 PRRC_aaa b:[0-9a-f]{8} withdrawn:2026-08-25 -->$' "$REVIEW"
}

@test "withdraw: records the reason where a reader will see it" {
    annotate
    withdraw "environments are deprecated"
    grep -q '^\*Withdrawn 2026-08-25: environments are deprecated\*$' "$REVIEW"
}

@test "withdraw: keeps the finding body, so the argument stays on the record" {
    annotate
    withdraw "not a real issue"
    grep -q "Validate the token first." "$REVIEW"
}

@test "withdraw: leaves the other finding alone" {
    annotate
    withdraw "reason"
    [ "$(grep -c 'withdrawn:' "$REVIEW")" -eq 1 ]
    grep -q '^#### `src/db.py:12` <!-- pc:888' "$REVIEW"
}

@test "withdraw: works without a reason" {
    annotate
    withdraw ""
    grep -q '^\*Withdrawn 2026-08-25\*$' "$REVIEW"
}

@test "withdraw: a withdrawn comment drops out of read and status" {
    annotate
    withdraw "reason"
    [ "$(python3 "$SCRIPT" read --review-file "$REVIEW" | jq '.comments | length')" -eq 1 ]
    run bash -c "jq -n '[]' | python3 '$SCRIPT' status --review-file '$REVIEW'"
    [ "$(echo "$output" | jq '.comments | length')" -eq 1 ]
}

@test "withdraw: withdrawing twice does not stack markers" {
    annotate
    withdraw "first"
    run withdraw "second"
    [[ "$output" == *'"withdrawn": 0'* ]]
    [ "$(grep -c 'withdrawn:' "$REVIEW")" -eq 1 ]
    [ "$(grep -c '^\*Withdrawn' "$REVIEW")" -eq 1 ]
}

@test "withdraw: reports an id it could not find" {
    annotate
    run bash -c "jq -n '[{id: 4242, reason: \"x\"}]' \
        | python3 '$SCRIPT' withdraw --review-file '$REVIEW' --date 2026-08-25"
    [ "$status" -eq 0 ]
    [[ "$output" == *'4242'* ]]
}

# A withdrawn finding must stay withdrawn through every later write. The
# path-and-line fallback in annotate is the way it could come back: a new
# finding at the same location would claim the retired block's annotation.
@test "withdraw: annotate leaves a withdrawn block alone and takes the live one" {
    cat > "$REVIEW" << 'EOF'
#### `src/auth.ts:42` <!-- pc:777 PRRC_aaa b:deadbeef withdrawn:2026-08-25 -->

```text
Old retired finding.
```

*Withdrawn 2026-08-25: author was right*

---

#### `src/auth.ts:42`

```text
A brand new finding at the same line.
```

---
EOF
    # A body matching neither block, which forces the path-and-line fallback.
    jq -n '[{id: 999, node_id: "PRRC_new", path: "src/auth.ts", line: 42,
             body: "Reworded on GitHub, matching nothing in the notes."}]' \
        | python3 "$SCRIPT" annotate --review-file "$REVIEW"

    grep -q '^#### `src/auth.ts:42` <!-- pc:777 PRRC_aaa b:deadbeef withdrawn:2026-08-25 -->$' "$REVIEW"
    grep -Eq '^#### `src/auth\.ts:42` <!-- pc:999 PRRC_new b:[0-9a-f]{8} -->$' "$REVIEW"
}

@test "withdraw: annotate never revives a withdrawn finding" {
    annotate
    withdraw "author was right"
    # Re-annotating, as a later --draft repost or refresh would.
    posted_json | python3 "$SCRIPT" annotate --review-file "$REVIEW" > /dev/null
    grep -q 'withdrawn:2026-08-25' "$REVIEW"
    [ "$("$PARSER" "$REVIEW" | jq '[.[] | select(.file == "src/auth.ts")] | length')" -eq 0 ]
}

@test "withdraw: set-body refuses to rewrite a retired finding" {
    annotate
    withdraw "author was right"
    run bash -c "jq -n '[{id: 777, body: \"should not land\"}]' \
        | python3 '$SCRIPT' set-body --review-file '$REVIEW'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"updated": 0'* ]]
    grep -q "Validate the token first." "$REVIEW"
}

# A review never posted as a draft has no heading token, only the prose line.
# Python has to honour it or annotate's filter lets the retired block be
# claimed by a new finding at the same path and line.
@test "withdraw: a hand-marked withdrawal is honoured without a heading token" {
    cat > "$REVIEW" << 'EOF'
#### `src/auth.ts:42`

```text
Retired by hand, never posted as a draft.
```

*Withdrawn 2026-08-25: author was right*

---

#### `src/auth.ts:42`

```text
A live finding at the same line.
```

---
EOF
    jq -n '[{id: 999, node_id: "PRRC_new", path: "src/auth.ts", line: 42,
             body: "Matches neither body, forcing the path and line fallback."}]' \
        | python3 "$SCRIPT" annotate --review-file "$REVIEW"

    # The hand-marked block keeps no annotation; the live one gets it.
    run grep -c 'pc:999' "$REVIEW"
    [ "$output" -eq 1 ]
    line_no=$(grep -n 'pc:999' "$REVIEW" | cut -d: -f1)
    [ "$line_no" -gt 5 ]
}

@test "status: identical bodies read as in_sync even with a stale digest" {
    annotate
    # Corrupt the recorded digest, as a dropped refresh would.
    sed -i.bak -E 's/ b:[0-9a-f]{8} / b:00000000 /' "$REVIEW"
    [ "$(status_of '.')" = "in_sync" ]
}
