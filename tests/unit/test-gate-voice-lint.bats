#!/usr/bin/env bats
# Tests for skills/review-code/scripts/gate-voice-lint.py

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    GATE="$PROJECT_ROOT/skills/review-code/scripts/gate-voice-lint.py"
    THREE_SENTENCES='`blocking`: `flush()` runs twice on retry. The second call drops the buffer. Guard it with a flag.'
    # 2 sentences and 40 words, with no inline code to make the count ambiguous.
    FORTY_WORDS="The retry loop calls flush on every attempt, so a request that fails three times writes the same buffer to the open socket three times. The client then receives duplicate rows that it cannot tell apart from the real ones."
    FORTY_ONE_WORDS="The retry loop calls flush on every attempt, so a request that fails three times writes the same buffer to the open socket three times. The client then receives duplicate rows that it cannot easily tell apart from the real ones."
}

field() {
    python3 -c "import json,sys; print(json.loads(sys.stdin.read())$1)"
}

# Lints one rewrite with id 1. An empty style leaves comment_style out, and an
# empty fix becomes a null proposed_fix.
lint_one() {
    local style="$1" body="$2" fix="${3:-}"
    jq -n --arg style "$style" --arg body "$body" --arg fix "$fix" '[
        {id: 1, description: $body, proposed_fix: (if $fix == "" then null else $fix end)}
        + (if $style == "" then {} else {comment_style: $style} end)
    ]' > "$BATS_TEST_TMPDIR/rewrites.json"
    "$GATE" "$BATS_TEST_TMPDIR/rewrites.json"
}

# Lints each argument as a concise rewrite with a null proposed_fix. The ids
# are 1, 2, and so on, in argument order.
lint_batch() {
    jq -n '$ARGS.positional | to_entries | map({
        id: (.key + 1), comment_style: "concise", description: .value, proposed_fix: null
    })' --args "$@" > "$BATS_TEST_TMPDIR/rewrites.json"
    "$GATE" "$BATS_TEST_TMPDIR/rewrites.json"
}

# The gate fails open, so a crash also reports zero warnings. Each check
# therefore requires a null error.
#
# Succeeds when the warned ids are exactly $2, [1] by default, and each warned
# rewrite has a warning of category $1 on its description.
has_warning() {
    jq -e --arg category "$1" --argjson ids "${2:-[1]}" '
        .error == null
        and .warned_ids == $ids
        and all(.findings[]; .warnings | any(.category == $category and .field == "description"))' \
        <<<"$output" >/dev/null
}

# Succeeds when the gate checked $1 rewrites, 1 by default, and warned none.
has_no_warning() {
    jq -e --argjson checked "${1:-1}" '.error == null and .checked == $checked and .warned == 0' <<<"$output" >/dev/null
}

# =============================================================================
# Script structure
# =============================================================================

@test "gate-voice-lint: script exists and is executable" {
    [ -f "$GATE" ]
    [ -x "$GATE" ]
}

@test "gate-voice-lint: has python3 shebang" {
    run head -1 "$GATE"
    [[ "$output" == "#!/usr/bin/env python3" ]]
}

@test "gate-voice-lint: loads the linter from its installed sibling path" {
    # The installed copy under ~/.claude is not a git checkout, so resolution
    # must not depend on git rev-parse.
    run grep -c "rev-parse" "$GATE"
    [[ "$output" == "0" ]]
}

# =============================================================================
# Clean and dirty bodies
# =============================================================================

@test "gate-voice-lint: clean bodies produce no warned ids" {
    run "$GATE" - <<'EOF'
[{"id": 1, "description": "`suggestion`: `users.py:67` fetches each profile inside the loop, so 100 users run 101 queries.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['warned']")" == "0" ]]
    [[ "$(echo "$output" | field "['clean']")" == "1" ]]
    [[ "$(echo "$output" | field "['checked']")" == "1" ]]
}

@test "gate-voice-lint: reports the id of a body that trips a rule" {
    run "$GATE" - <<'EOF'
[{"id": 7, "description": "`blocking`: the read is not pinned by any test.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['warned_ids']")" == "[7]" ]]
    [[ "$(echo "$output" | field "['findings'][0]['warnings'][0]['category']")" == "pinning" ]]
}

@test "gate-voice-lint: lints proposed_fix as well as description" {
    run "$GATE" - <<'EOF'
[{"id": 2, "description": "`suggestion`: `users.py:67` runs 101 queries.", "proposed_fix": "Leverage the existing helper."}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['warned_ids']")" == "[2]" ]]
    [[ "$(echo "$output" | field "['findings'][0]['warnings'][0]['field']")" == "proposed_fix" ]]
}

@test "gate-voice-lint: separates clean from warned across a batch" {
    run "$GATE" - <<'EOF'
[{"id": 1, "description": "`blocking`: the cache stays stale for 300 seconds.", "proposed_fix": null},
 {"id": 2, "description": "`nit`: this pins the behavior.", "proposed_fix": null},
 {"id": 3, "description": "`question`: does `flush()` run twice here?", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['checked']")" == "3" ]]
    [[ "$(echo "$output" | field "['clean']")" == "2" ]]
    [[ "$(echo "$output" | field "['warned_ids']")" == "[2]" ]]
}

@test "gate-voice-lint: code blocks in a body do not trip prose rules" {
    run "$GATE" - <<'EOF'
[{"id": 1, "description": "`suggestion`: call the helper instead.\n```python\nleverage_ensure_robust()\n```", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['warned']")" == "0" ]]
}

@test "gate-voice-lint: gate used as a verb sends the body to voice repair" {
    run lint_one concise '`blocking`: This says `experiment.update` checks release conditions, but the backend never gates them.'

    [ "$status" -eq 0 ]
    has_warning code_term_verb
}

@test "gate-voice-lint: a quoted word as the subject of an action verb sends the body to voice repair" {
    run lint_one concise "$(jq -r '.cases[0].draft' "$PROJECT_ROOT/tests/fixtures/finding-comments/pr-118814.json")"

    [ "$status" -eq 0 ]
    has_warning action_subject
    has_warning negative_subject
}

# =============================================================================
# Concise length
# =============================================================================

@test "gate-voice-lint: a concise body with three sentences gets a length warning" {
    run lint_batch \
        "$THREE_SENTENCES" \
        $'`blocking`: `flush()` runs twice on retry.\n\nThe second call drops the buffer.\n\nGuard it with a flag.' \
        '`question`: Does `flush()` run twice on retry? The second call would drop the buffer. Should it check a flag first?' \
        '`blocking`: `flush()` runs twice on retry. The second call drops the buffer. Guard it with a flag'

    [ "$status" -eq 0 ]
    has_warning concise_length '[1, 2, 3, 4]' || {
        echo "expected a length warning on ids 1-4, got: $(jq -c '{error, findings: [.findings[] | {id, categories: [.warnings[].category]}]}' <<<"$output")"
        false
    }
}

@test "gate-voice-lint: a concise body over 40 words gets a length warning in two sentences" {
    run lint_one concise "\`blocking\`: $FORTY_ONE_WORDS"

    [ "$status" -eq 0 ]
    has_warning concise_length
}

@test "gate-voice-lint: an inline code span counts as one word of concise length" {
    run lint_one concise "\`blocking\`: ${FORTY_ONE_WORDS/calls flush/calls \`flush()\`}"

    [ "$status" -eq 0 ]
    has_warning concise_length
}

@test "gate-voice-lint: a concise body of two sentences and 40 words passes the length check" {
    run lint_one concise "\`blocking\`: $FORTY_WORDS"

    [ "$status" -eq 0 ]
    has_no_warning
}

@test "gate-voice-lint: the severity prefix does not count toward the concise length" {
    local prefix bodies=()
    for prefix in '`blocking`:' 'blocking:' '**blocking**:' '`suggestion`:' 'nit:' '`question`:'; do
        bodies+=("$prefix $FORTY_WORDS")
    done

    run lint_batch "${bodies[@]}"

    [ "$status" -eq 0 ]
    has_no_warning 6 || {
        echo "prefix counted toward the length: $(jq -c '{error, warned_ids}' <<<"$output")"
        false
    }
}

@test "gate-voice-lint: code blocks do not count toward the concise length" {
    local code='# Flush once. Close the writer. Log the result for every retry attempt that the loop makes, then reset the flag so that the next request starts clean and writes its own buffer to the socket exactly one time.
if not self._flushed:
    self.flush()'

    run lint_batch \
        $'`suggestion`: `flush()` runs on every retry and drops the buffer. Flush once per request instead.\n```suggestion\n'"$code"$'\n```' \
        $'`blocking`: `flush()` runs on every retry and drops the buffer.\n```python\n'"$code"$'\n```\nFlush once per request instead.' \
        $'`blocking`: `flush()` runs on every retry and drops the buffer. Flush once per request instead.\n~~~python\n'"$code"$'\n~~~'

    [ "$status" -eq 0 ]
    has_no_warning 3 || {
        echo "code block counted toward the length: $(jq -c '{error, warned_ids}' <<<"$output")"
        false
    }
}

@test "gate-voice-lint: periods in abbreviations, numbers, and inline code do not end a sentence" {
    run lint_batch \
        '`suggestion`: Use a typed value, e.g. an enum, for `mode`. That keeps the match exhaustive.' \
        '`blocking`: The retry waits 1.5 seconds on v2.3.1 before it reads `users.py`. Cap the wait at the request timeout.' \
        '`nit`: The log line `Retrying. Please wait.` repeats on every attempt. Log it once per request.'

    [ "$status" -eq 0 ]
    has_no_warning 3 || {
        echo "unexpected length warning: $(jq -c '{error, warned_ids}' <<<"$output")"
        false
    }
}

@test "gate-voice-lint: a detailed body gets no length warning" {
    run lint_one detailed '`blocking`: The retry loop calls `flush()` on every attempt. A request that fails three times writes the same buffer three times. The client then receives duplicate rows that it cannot tell apart from the real ones. Guard the second call with a flag on the writer, and add a test that retries three times and asserts one write.'

    [ "$status" -eq 0 ]
    has_no_warning
}

# compose gives every finding the concise style when it has none.
@test "gate-voice-lint: a body without comment_style is checked as concise" {
    run lint_one "" "$THREE_SENTENCES"

    [ "$status" -eq 0 ]
    has_warning concise_length
}

# Only description is posted. proposed_fix stays in the local review.
@test "gate-voice-lint: proposed_fix does not count toward the concise length" {
    run lint_one concise '`blocking`: `flush()` runs twice on retry and drops the buffer.' \
        'Wrap the second call in a check of the flag. Set the flag after the first flush succeeds. Reset it when the writer reopens. Add a test that retries three times and asserts one write.'

    [ "$status" -eq 0 ]
    has_no_warning
}

@test "gate-voice-lint: the length check follows each finding's own style in a batch" {
    jq -n --arg long "$THREE_SENTENCES" '[
        {id: 1, comment_style: "concise", description: $long, proposed_fix: null},
        {id: 2, comment_style: "detailed", description: $long, proposed_fix: null},
        {id: 3, comment_style: "concise", description: "`nit`: Rename `x` to `count`.", proposed_fix: null}
    ]' > "$BATS_TEST_TMPDIR/batch.json"

    run "$GATE" "$BATS_TEST_TMPDIR/batch.json"

    [ "$status" -eq 0 ]
    jq -e '.error == null and .checked == 3 and .warned_ids == [1]' <<<"$output"
}

# A body that is only too long keeps its voice rewrite, because the final
# comprehension gate also judges length.
@test "gate-voice-lint: restore_ids lists the warned ids with a warning other than concise_length" {
    run lint_batch \
        "$THREE_SENTENCES" \
        '`blocking`: The status is logged, but nothing checks it.' \
        "$THREE_SENTENCES But nothing checks the status." \
        '`nit`: Rename `x` to `count`.'

    [ "$status" -eq 0 ]
    jq -e '.error == null and .warned_ids == [1, 2, 3] and .restore_ids == [2, 3]' <<<"$output"
    jq -e '[.findings[] | {id, categories: ([.warnings[].category] | unique)}] == [
        {id: 1, categories: ["concise_length"]},
        {id: 2, categories: ["negative_subject"]},
        {id: 3, categories: ["concise_length", "negative_subject"]}
    ]' <<<"$output"

    run "$GATE" - <<<'not json at all'

    [ "$status" -eq 0 ]
    jq -e '.error != null and .restore_ids == []' <<<"$output"
}

# =============================================================================
# Payload capping
# =============================================================================

@test "gate-voice-lint: --limit caps warnings per finding and counts the rest" {
    run "$GATE" --limit 2 - <<'EOF'
[{"id": 1, "description": "`blocking`: this pins the behavior.\nIt is not pinned anywhere.\nThe read is pinned by a test.\nNothing pinned elsewhere covers it.\nThe contract isn't pinned.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['findings'][0]['warnings'].__len__()")" == "2" ]]
    [[ "$(echo "$output" | field "['findings'][0]['suppressed']")" -gt 0 ]]
}

@test "gate-voice-lint: --limit 0 keeps every warning" {
    run "$GATE" --limit 0 - <<'EOF'
[{"id": 1, "description": "`blocking`: this pins the behavior.\nIt is not pinned anywhere.\nThe read is pinned by a test.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    run bash -c "echo '$output' | python3 -c \"import json,sys; print('suppressed' in json.load(sys.stdin)['findings'][0])\""
    [[ "$output" == "False" ]]
}

# =============================================================================
# Fail-open contract
# =============================================================================

@test "gate-voice-lint: malformed JSON fails open with exit 0 and an error field" {
    run bash -c "printf 'not json at all' | '$GATE' -"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['checked']")" == "0" ]]
    [[ "$(echo "$output" | field "['warned_ids']")" == "[]" ]]
    run bash -c "printf 'not json at all' | '$GATE' - | python3 -c \"import json,sys; print(json.load(sys.stdin)['error'] is not None)\""
    [[ "$output" == "True" ]]
}

@test "gate-voice-lint: a JSON object instead of an array fails open" {
    run bash -c "printf '{\"id\": 1}' | '$GATE' -"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['error']")" == *"must be a JSON array"* ]]
}

@test "gate-voice-lint: an empty array reports nothing to revert" {
    run bash -c "printf '[]' | '$GATE' -"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['checked']")" == "0" ]]
    [[ "$(echo "$output" | field "['error']")" == "None" ]]
}

@test "gate-voice-lint: a missing input file fails open rather than erroring out" {
    run "$GATE" /nonexistent/path/to/rewrites.json
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['error']")" == *"FileNotFoundError"* ]]
}

@test "gate-voice-lint: a null proposed_fix is skipped without failing" {
    run "$GATE" - <<'EOF'
[{"id": 1, "description": "`nit`: rename `x` to `count`.", "proposed_fix": null}]
EOF
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['error']")" == "None" ]]
    [[ "$(echo "$output" | field "['clean']")" == "1" ]]
}
