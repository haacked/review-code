#!/usr/bin/env bats
# Tests for skills/review-code/scripts/lint-comment-voice.py

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    LINTER="$PROJECT_ROOT/skills/review-code/scripts/lint-comment-voice.py"
}

# Lints the phrases on stdin in one run, one phrase per line. Outside code
# fences and metadata blocks, the linter checks each line on its own. A phrase
# therefore gets the warnings it would get alone.
lint_phrases() {
    cat > "$BATS_TEST_TMPDIR/phrases.md"
    run "$LINTER" - < "$BATS_TEST_TMPDIR/phrases.md"
}

# Succeeds when every line linted by lint_phrases has a warning of category $1.
# Prints each phrase that has none.
every_line_has_warning() {
    local unflagged
    unflagged=$(jq -sr --arg category "$1" --rawfile phrases "$BATS_TEST_TMPDIR/phrases.md" '
        (flatten | map(select(.category == $category) | .line)) as $flagged
        | $phrases | rtrimstr("\n") | split("\n") | to_entries[]
        | select(.key + 1 | IN($flagged[]) | not) | .value' <<<"$output")
    [ -z "$unflagged" ] || {
        echo "no $1 warning for:"
        echo "$unflagged"
        return 1
    }
}

# Succeeds when no line linted by lint_phrases has a warning of category $1.
# Prints each phrase that has one.
no_line_has_warning() {
    local flagged
    flagged=$(jq -sr --arg category "$1" 'flatten | .[] | select(.category == $category) | .text' <<<"$output")
    [ -z "$flagged" ] || {
        echo "unexpected $1 warning for:"
        echo "$flagged"
        return 1
    }
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "lint-comment-voice: script exists and is executable" {
    [ -f "$LINTER" ]
    [ -x "$LINTER" ]
}

@test "lint-comment-voice: has python3 shebang" {
    run head -1 "$LINTER"
    [[ "$output" == "#!/usr/bin/env python3" ]]
}

# =============================================================================
# Clean input
# =============================================================================

@test "lint-comment-voice: clean comment body produces no warnings" {
    run "$LINTER" - <<'EOF'
`blocking`: `validate_user` doesn't check whether `email` is `None`, so a request without an email raises a 500. Add a null check at the top of the function.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "lint-comment-voice: exit 1 with --fail-on-warnings when warnings exist" {
    run bash -c "printf 'The cache — see client.py — stays stale.\n' | '$LINTER' --fail-on-warnings - >/dev/null"
    [ "$status" -eq 1 ]
}

@test "lint-comment-voice: exit 0 without --fail-on-warnings even when warnings exist" {
    run bash -c "printf 'The cache — see client.py — stays stale.\n' | '$LINTER' - >/dev/null"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Masking: code and metadata are not prose
# =============================================================================

@test "lint-comment-voice: fenced code blocks are ignored" {
    run "$LINTER" - <<'EOF'
`suggestion`: Publish the invalidation instead.
```python
cache.publish_invalidation(key)  # leverage the existing channel — it works
```
The body reads fine.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "lint-comment-voice: nested fences stay masked and prose keeps its line number" {
    run "$LINTER" - <<'EOF'
   ````markdown
```python
The cache leverages the helper.
```
~~~~
```` trailing text
This is a comprehensive rewrite.
  `````
The cache leverages the helper.
EOF
    [ "$status" -eq 0 ]
    jq -se 'length == 1 and .[0].line == 9 and .[0].category == "ai_vocabulary"' <<<"$output"
}

@test "lint-comment-voice: an unterminated fence masks prose through EOF" {
    run "$LINTER" - <<'EOF'
The cache clears on write.
~~~python
The cache leverages the helper.
```
~~~ trailing text
This is a comprehensive rewrite.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "lint-comment-voice: inline code is ignored" {
    run "$LINTER" - <<'EOF'
`nit`: Call `cache.invalidate — fast path` directly here instead.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "lint-comment-voice: URLs are ignored" {
    run "$LINTER" - <<'EOF'
See https://example.com/leverage—the-docs for background on the format.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "lint-comment-voice: review-metadata comment block is ignored" {
    run "$LINTER" - <<'EOF'
<!-- review-metadata
reasoning: comprehensive — leverage the full agent set
-->
`nit`: Drop the unused import.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "lint-comment-voice: severity prefix is not prose" {
    run "$LINTER" - <<'EOF'
`**Issue**: blocking`: The rename drops the old key without a fallback.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

# =============================================================================
# Review-dialect rules
# =============================================================================

@test "lint-comment-voice: flags em dashes and en dashes in prose" {
    run "$LINTER" - <<'EOF'
The cache stays stale for up to an hour after deploy — every gate switched off in that window.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"dash"'* ]]
}

@test "lint-comment-voice: flags 'pin' used as a test-coverage verb" {
    run "$LINTER" - <<'EOF'
The TTL argument is already pinned elsewhere in the suite.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"pinning"'* ]]
}

@test "lint-comment-voice: allows literal version and SHA pinning" {
    run "$LINTER" - <<'EOF'
The base image is pinned to sha256:4a1f and the action pins v2.3.1.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

# The voice agent and the agent briefing name this family phrase by phrase. If a
# phrase they ban stops firing here, the lint gate silently stops enforcing it.
@test "lint-comment-voice: flags every pin phrase the voice rules ban" {
    while IFS= read -r phrase; do
        run bash -c "printf '%s\n' \"\$1\" | '$LINTER' -" _ "$phrase"
        [ "$status" -eq 0 ]
        [[ "$output" == *'"pinning"'* ]] || {
            echo "no pinning warning for: $phrase"
            false
        }
    done <<'EOF'
the contract isn't pinned
the timeout is pinned by a test
this pins the behavior
the read is not pinned by any case
that path is pinned elsewhere in the suite
pin the actual behavior here
EOF
}

@test "lint-comment-voice: flags every verdict opener the voice rules ban" {
    while IFS= read -r phrase; do
        run bash -c "printf '%s\n' \"\$1\" | '$LINTER' -" _ "$phrase"
        [ "$status" -eq 0 ]
        [[ "$output" == *'"verdict_opener"'* ]] || {
            echo "no verdict_opener warning for: $phrase"
            false
        }
    done <<'EOF'
Sound and proportionate.
The new machinery is in good shape.
Direct, well-scoped change.
This is a real upgrade-window risk.
In good shape overall.
EOF
}

@test "lint-comment-voice: flags a sentence that opens with a negative subject" {
    while IFS= read -r phrase; do
        run bash -c "printf '%s\n' \"\$1\" | '$LINTER' -" _ "$phrase"
        [ "$status" -eq 0 ]
        [[ "$output" == *'"negative_subject"'* ]] || {
            echo "no negative_subject warning for: $phrase"
            false
        }
    done <<'EOF'
`suggestion`: No test covers the expired-token path.
Nothing checks that the status is 200.
The retry is fine. Nobody calls it with a zero timeout.
`nit`: None of the callers pass `strict`.
No caller passes `strict`, so the branch never runs.
No jest test runs this branch with a string value.
No tests verify the expired-token path.
No tests catch this.
No callers reach this branch.
No test exists for the expired-token path.
No test hits this branch.
EOF
}

@test "lint-comment-voice: leaves negated verbs and other uses of no alone" {
    while IFS= read -r phrase; do
        run bash -c "printf '%s\n' \"\$1\" | '$LINTER' -" _ "$phrase"
        [ "$status" -eq 0 ]
        [[ "$output" != *'"negative_subject"'* ]] || {
            echo "unexpected negative_subject warning for: $phrase"
            false
        }
    done <<'EOF'
The expired-token path isn't tested.
It doesn't change anything that already exists.
No, the retry already handles that.
No longer needed after the migration.
This returns no rows when the team has no plan.
`question`: Is there no test for this, or did I miss it?
No need to check the status here.
No need to call it again here.
No need to set it twice.
No extra test needed.
No regression test needed here: the fixture already covers it.
EOF
}

@test "lint-comment-voice: flags a negative subject after a comma and a conjunction" {
    lint_phrases <<'EOF'
The helper exists, but nothing calls it.
The retry runs on every call, so nobody notices the duplicate write.
The worker writes the row, and no one reads it back.
The flag exists, yet none of the callers pass `strict`.
`suggestion`: The status is logged, but nothing checks it.
But nothing checks the status.
The status is logged. But no caller checks it.
EOF
    [ "$status" -eq 0 ]
    every_line_has_warning negative_subject
}

@test "lint-comment-voice: leaves a negative word that is not a clause subject alone" {
    lint_phrases <<'EOF'
The retry runs, but it changes nothing.
This returns nothing when the cache is empty.
The worker retries, and the second attempt finds no one waiting.
The cache is cold, so the first read returns no rows.
EOF
    [ "$status" -eq 0 ]
    no_line_has_warning negative_subject
}

@test "lint-comment-voice: flags a No-subject sentence whose verb is gates, requires, or needs" {
    lint_phrases <<'EOF'
No check gates targeting edits.
No caller requires the lock.
No test needs the fixture.
No route handler requires a token.
`blocking`: No caller needs `strict`.
EOF
    [ "$status" -eq 0 ]
    every_line_has_warning negative_subject
}

@test "lint-comment-voice: leaves No phrases built on required or needed alone" {
    lint_phrases <<'EOF'
No migration required for this change.
No extra setup needed.
No need to require the lock here.
No longer requires the lock.
No changes needed here.
EOF
    [ "$status" -eq 0 ]
    no_line_has_warning negative_subject
}

# Every body the lint gate receives opens with a severity prefix. Masking
# deletes the backticked word and leaves a bare ": ", which used to defeat
# every start-anchored rule, so the whole verdict-opener family passed the gate
# while the unprefixed test above went on passing.
@test "lint-comment-voice: flags a verdict opener behind a severity prefix" {
    while IFS= read -r phrase; do
        run bash -c "printf '%s\n' \"\$1\" | '$LINTER' -" _ "$phrase"
        [ "$status" -eq 0 ]
        [[ "$output" == *'"verdict_opener"'* ]] || {
            echo "no verdict_opener warning for: $phrase"
            false
        }
    done <<'EOF'
`blocking`: This is a real upgrade-window risk.
`suggestion`: Sound and proportionate.
`nit`: The new machinery is in good shape.
**blocking**: In good shape overall.
blocking: Direct, well-scoped change.
EOF
}

# Reviews separate the severity token with an em dash as often as with a colon.
# Treating only the colon as a prefix left the structural dash in the prose,
# so the dash rule reported on every dash-separated finding title.
@test "lint-comment-voice: a dash-separated severity prefix is not prose" {
    run "$LINTER" - <<'EOF'
**`question` — the doc comment claims a retry the code does not have.**
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "lint-comment-voice: a dash inside the body still reports" {
    run "$LINTER" - <<'EOF'
`blocking`: the cache stays stale — see client.py — after deploy.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"dash"'* ]]
}

@test "lint-comment-voice: flags a pseudo-header behind a severity prefix" {
    run "$LINTER" - <<'EOF'
`blocking`: **Issue**: the request raises a 500.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"pseudo_header"'* ]]
}

@test "lint-comment-voice: a clean prefixed body stays clean" {
    run "$LINTER" - <<'EOF'
`suggestion`: `users.py:67` fetches each profile inside the loop, so a request for 100 users runs 101 queries.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "lint-comment-voice: leaves the version and SHA pinning the rules exempt" {
    while IFS= read -r phrase; do
        run bash -c "printf '%s\n' \"\$1\" | '$LINTER' -" _ "$phrase"
        [ "$status" -eq 0 ]
        [[ "$output" == "[]" ]] || {
            echo "unexpected warning for exempt phrase: $phrase"
            false
        }
    done <<'EOF'
The dependency is pinned to `v2.4.1` in the lockfile.
The action is pinned to that SHA.
`requests` stays pinned at 2.31.0.
EOF
}

@test "lint-comment-voice: flags AI vocabulary" {
    run "$LINTER" - <<'EOF'
This leverages the existing validator to ensure the robust, comprehensive handling of every case.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"ai_vocabulary"'* ]]
}

@test "lint-comment-voice: flags verdict-first opinion openers" {
    run "$LINTER" - <<'EOF'
This is a real upgrade-window risk on self-hosted.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"verdict_opener"'* ]]
}

@test "lint-comment-voice: flags pseudo-headers" {
    run "$LINTER" - <<'EOF'
**Issue**: the rename drops the old key. **Impact**: self-hosted orgs lose the gate.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"pseudo_header"'* ]]
}

# =============================================================================
# Code nouns used as verbs
# =============================================================================

# Approval code calls its check a gate. A comment that also uses "gate" as a
# verb makes the reader stop to work out which one each sentence means.
@test "lint-comment-voice: flags gate used as a verb" {
    lint_phrases <<'EOF'
The backend never gates them.
This holds even when `after` gates fewer writes than `now`.
Compare the gated operations before and after the change.
List the flags a rollout ungates.
The middleware is gating every write.
Ungate the flag after the migration finishes.
The rollout leaves both flags ungated.
Gated writes skip the audit log.
`blocking`: the backend never gates them.
EOF
    [ "$status" -eq 0 ]
    every_line_has_warning code_term_verb
}

@test "lint-comment-voice: leaves gate nouns, code spans, and identifiers alone" {
    lint_phrases <<'EOF'
The approval gate rejects it.
The flag write gate runs before the save.
The test table marks this row `UNGATED`.
`if rollout.gates(flag): return` skips the save.
Each row in the test table uses the UNGATED constant.
The is_gated helper returns early.
The isGated helper returns early.
The ungated_flags list stays empty.
The GATES_ENABLED setting is off in tests.
The flag.gated attribute is read once.
See src/gates/rules.py for the list.
The check lives in gates.py now.
EOF
    [ "$status" -eq 0 ]
    no_line_has_warning code_term_verb
}

@test "lint-comment-voice: gate verbs inside a fenced code block are ignored" {
    run "$LINTER" - <<'EOF'
`suggestion`: Check the rollout before the save.
```python
if rollout.gates(flag) and not flag.ungated:
    return  # the rollout gates this write
```
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "lint-comment-voice: flags the gate verb and the negative subject in one approval comment" {
    run "$LINTER" - <<'EOF'
This says `experiment.update` gates release condition changes, but nothing gates targeting edits.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"code_term_verb"'* ]]
    [[ "$output" == *'"negative_subject"'* ]]
}

# =============================================================================
# Length
# =============================================================================

# lint-review-narrative.py runs the same rules over a whole review document,
# and detailed comments have no length limit. Only gate-voice-lint.py applies
# the concise limit, because only it knows a finding's comment style.
@test "lint-comment-voice: a long body gets no length warning from the linter alone" {
    run "$LINTER" - <<'EOF'
`blocking`: The retry loop calls `flush()` on every attempt. A request that fails three times writes the same buffer three times. The client then receives duplicate rows. It cannot tell them apart from the real ones. Guard the second call with a flag on the writer.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

# =============================================================================
# Input handling
# =============================================================================

@test "lint-comment-voice: reads a file argument" {
    printf 'The cache — see client.py — stays stale.\n' > "$BATS_TEST_TMPDIR/body.md"
    run "$LINTER" "$BATS_TEST_TMPDIR/body.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"line": 1'* ]]
}

@test "lint-comment-voice: --limit caps reported messages per category" {
    run bash -c "{ for i in 1 2 3; do echo \"The cache — stale again — on run \$i.\"; done } | '$LINTER' --limit 1 -"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"suppressed": 2'* ]]
    [ "$(grep -c '"category": "dash"' <<<"$output")" -eq 1 ]
}

@test "lint-comment-voice: each warning carries line, message, and text" {
    run "$LINTER" - <<'EOF'
first line fine
The cache — see client.py — stays stale.
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *'"line": 2'* ]]
    [[ "$output" == *'"message":'* ]]
    [[ "$output" == *'"text":'* ]]
}
