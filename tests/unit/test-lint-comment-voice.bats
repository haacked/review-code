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
