#!/usr/bin/env bats
# Tests for skills/review-code/scripts/lint-review-narrative.py

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    NARRATIVE="$PROJECT_ROOT/skills/review-code/scripts/lint-review-narrative.py"
    PARSER="$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh"
    REVIEW="$BATS_TEST_TMPDIR/review.md"
}

field() {
    python3 -c "import json,sys; print(json.loads(sys.stdin.read())$1)"
}

categories() {
    python3 -c "import json,sys; print(sorted({w['category'] for w in json.load(sys.stdin)['warnings']}))"
}

write_review() {
    cat > "$REVIEW"
}

# =============================================================================
# Script structure
# =============================================================================

@test "lint-review-narrative: script exists and is executable" {
    [ -f "$NARRATIVE" ]
    [ -x "$NARRATIVE" ]
}

@test "lint-review-narrative: has python3 shebang" {
    run head -1 "$NARRATIVE"
    [[ "$output" == "#!/usr/bin/env python3" ]]
}

@test "lint-review-narrative: loads the linter from its installed sibling path" {
    run grep -c "rev-parse" "$NARRATIVE"
    [[ "$output" == "0" ]]
}

# =============================================================================
# Whitelist: which sections count as narrative
# =============================================================================

@test "lint-review-narrative: lints the Overview body" {
    write_review <<'EOF'
# Branch Review: feature vs main

## Overview

This is a comprehensive rewrite of the cache layer.
EOF
    run "$NARRATIVE" "$REVIEW"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['count']")" == "1" ]]
    [[ "$(echo "$output" | categories)" == *"hype"* ]]
}

@test "lint-review-narrative: lints per-agent Review section prose" {
    write_review <<'EOF'
## Security Review

The new guard leverages the existing validator.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | categories)" == *"ai_vocabulary"* ]]
}

@test "lint-review-narrative: skips the metadata header" {
    write_review <<'EOF'
<!-- review-metadata
reasoning: Running a comprehensive review to leverage every agent.
-->

## Overview

The cache clears on write.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | field "['count']")" == "0" ]]
}

@test "lint-review-narrative: skips Fix Summary and Suggested Comments" {
    write_review <<'EOF'
## Fix Summary

A comprehensive fix that leverages the helper.

## Suggested Comments

`blocking`: this is not pinned by any test.

## Overview

The cache clears on write.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | field "['count']")" == "0" ]]
}

@test "lint-review-narrative: an H1 ends the current narrative section" {
    write_review <<'EOF'
## Overview

The cache clears on write.

# Re-review at abc1234

This delta leverages the earlier findings.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | field "['count']")" == "0" ]]
}

# =============================================================================
# Finding spans inside narrative sections
# =============================================================================

@test "lint-review-narrative: skips a finding body inside a Review section" {
    write_review <<'EOF'
## Testing Review

The suite covers the new module.

`blocking`: the read is not pinned by any test and leverages the old helper.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | field "['count']")" == "0" ]]
}

@test "lint-review-narrative: skips every paragraph of a multi-paragraph finding" {
    write_review <<'EOF'
## Correctness Review

The claims check out.

`blocking`: the cache stays stale.

This is a comprehensive failure of the invalidation path.

Adding a publish call leverages the existing channel.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | field "['count']")" == "0" ]]
}

@test "lint-review-narrative: narrative after a thematic break is linted again" {
    write_review <<'EOF'
## Testing Review

`blocking`: the cache stays stale and leverages the old path.

---

Both findings are comprehensive in scope.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | field "['count']")" == "1" ]]
    [[ "$(echo "$output" | categories)" == *"hype"* ]]
}

@test "lint-review-narrative: a thematic break inside a fenced block does not end the finding" {
    write_review <<'EOF'
## Testing Review

`blocking`: replace the call.

```diff
--- a/cache.py
+++ b/cache.py
```

This leverages the existing channel.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | field "['count']")" == "0" ]]
}

@test "lint-review-narrative: reported line numbers point at the review file" {
    write_review <<'EOF'
## Overview

Line three is clean.

The cache leverages the helper on line five.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | field "['warnings'][0]['line']")" == "5" ]]
}

# =============================================================================
# Annotation
# =============================================================================

@test "lint-review-narrative: --annotate appends a Lint notes section" {
    write_review <<'EOF'
## Overview

This is a comprehensive rewrite.
EOF
    run "$NARRATIVE" --annotate "$REVIEW"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['annotated']")" == "True" ]]
    run grep -c '^## Lint notes$' "$REVIEW"
    [[ "$output" == "1" ]]
    run grep -c '^> line 3, hype:' "$REVIEW"
    [[ "$output" == "1" ]]
}

@test "lint-review-narrative: --annotate is idempotent across repeated runs" {
    write_review <<'EOF'
## Overview

This is a comprehensive rewrite.
EOF
    "$NARRATIVE" --annotate "$REVIEW" > /dev/null
    "$NARRATIVE" --annotate "$REVIEW" > /dev/null
    "$NARRATIVE" --annotate "$REVIEW" > /dev/null
    run grep -c '^## Lint notes$' "$REVIEW"
    [[ "$output" == "1" ]]
    run grep -c '^> line 3, hype:' "$REVIEW"
    [[ "$output" == "1" ]]
}

@test "lint-review-narrative: --annotate removes a stale section when the prose is clean" {
    write_review <<'EOF'
## Overview

This is a comprehensive rewrite.
EOF
    "$NARRATIVE" --annotate "$REVIEW" > /dev/null
    write_review <<'EOF'
## Overview

The cache clears on write.

## Lint notes

Voice-lint warnings on this review's narrative prose.

> line 3, hype: This is a comprehensive rewrite.
EOF
    run "$NARRATIVE" --annotate "$REVIEW"
    [[ "$(echo "$output" | field "['annotated']")" == "False" ]]
    run grep -c '^## Lint notes$' "$REVIEW"
    [[ "$output" == "0" ]]
}

@test "lint-review-narrative: an existing Lint notes section is not itself linted" {
    write_review <<'EOF'
## Overview

The cache clears on write.

## Lint notes

Voice-lint warnings on this review's narrative prose.

> line 3, hype: This is a comprehensive rewrite that leverages the helper.
EOF
    run "$NARRATIVE" "$REVIEW"
    [[ "$(echo "$output" | field "['count']")" == "0" ]]
}

@test "lint-review-narrative: without --annotate the file is unchanged" {
    write_review <<'EOF'
## Overview

This is a comprehensive rewrite.
EOF
    before="$(md5 -q "$REVIEW" 2>/dev/null || md5sum "$REVIEW" | cut -d' ' -f1)"
    "$NARRATIVE" "$REVIEW" > /dev/null
    after="$(md5 -q "$REVIEW" 2>/dev/null || md5sum "$REVIEW" | cut -d' ' -f1)"
    [[ "$before" == "$after" ]]
}

@test "lint-review-narrative: the Lint notes section adds no findings to the parser" {
    write_review <<'EOF'
## Security Review

The new guard is comprehensive.

#### `auth.py:45`

`blocking`: the request raises a 500.

[Security 85%]
EOF
    before="$("$PARSER" "$REVIEW" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
    "$NARRATIVE" --annotate "$REVIEW" > /dev/null
    after="$("$PARSER" "$REVIEW" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
    [[ "$before" == "$after" ]]
    run grep -c '^## Lint notes$' "$REVIEW"
    [[ "$output" == "1" ]]
}

@test "lint-review-narrative: --limit caps warnings per category" {
    write_review <<'EOF'
## Overview

This is a comprehensive rewrite.
The comprehensive migration lands next.
A comprehensive test suite follows.
EOF
    run "$NARRATIVE" --limit 1 "$REVIEW"
    run bash -c "'$NARRATIVE' --limit 1 '$REVIEW' | python3 -c \"import json,sys; print(len(json.load(sys.stdin)['warnings']))\""
    [[ "$output" == "1" ]]
}

# =============================================================================
# Fail-open contract
# =============================================================================

@test "lint-review-narrative: a missing file fails open with exit 0" {
    run "$NARRATIVE" /nonexistent/path/review.md
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['count']")" == "0" ]]
    [[ "$(echo "$output" | field "['error']")" == *"FileNotFoundError"* ]]
}

@test "lint-review-narrative: --annotate on a missing file leaves nothing behind" {
    run "$NARRATIVE" --annotate /nonexistent/path/review.md
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['annotated']")" == "False" ]]
    [ ! -f /nonexistent/path/review.md ]
}

@test "lint-review-narrative: an empty review file reports no warnings" {
    : > "$REVIEW"
    run "$NARRATIVE" --annotate "$REVIEW"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | field "['count']")" == "0" ]]
    [[ "$(echo "$output" | field "['error']")" == "None" ]]
}
