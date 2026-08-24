#!/usr/bin/env bats
# Tests for skills/review-code/scripts/lint-comment-voice.py

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    LINTER="$PROJECT_ROOT/skills/review-code/scripts/lint-comment-voice.py"
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
