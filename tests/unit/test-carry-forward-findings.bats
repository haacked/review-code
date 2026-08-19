#!/usr/bin/env bats
# Tests for carry-forward-findings.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/carry-forward-findings.sh"
    export SCRIPT

    TEST_DIR=$(mktemp -d)
    export TEST_DIR

    cat > "$TEST_DIR/review.md" << 'EOF'
<!-- review-metadata
reviewed_at: 2026-08-01T10:00:00Z
mode: pr
pr_number: 42
review_commit: aaaaaaa
-->

# Pull Request Review: #42 - Add a thing

## Security Review

#### `src/auth.py:45`

Token comparison is not constant time, so a remote attacker can time it.

```bash
# this comment must not look like a heading
compare a b
```

#### `src/untouched.py:10`

Missing input validation on the forwarded header.

## Testing Review

### Nits

#### `docs/readme.md:3`

Typo in the heading.
EOF

    cat > "$TEST_DIR/delta.patch" << 'EOF'
diff --git a/src/auth.py b/src/auth.py
--- a/src/auth.py
+++ b/src/auth.py
@@ -40,6 +40,7 @@
 unchanged
EOF

    cat > "$TEST_DIR/append.md" << 'EOF'
# Re-review at deadbee

## Security Review

#### `src/auth.py:47`

The compare is fixed, the fallback path still leaks length.
EOF
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "carry-forward-findings.sh: exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "carry-forward-findings.sh: requires a review file" {
    run "$SCRIPT" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--review-file is required"* ]]
}

@test "carry-forward-findings.sh: requires a delta diff" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--delta-diff is required"* ]]
}

@test "carry-forward-findings.sh: errors when the review file is missing" {
    run "$SCRIPT" --review-file "$TEST_DIR/nope.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "carry-forward-findings.sh: cuts findings on files the delta touched" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pruned == true' > /dev/null
    echo "$output" | jq -e '.dropped == 1' > /dev/null
    echo "$output" | jq -e '.dropped_files == ["src/auth.py"]' > /dev/null
    ! grep -q "constant time" "$TEST_DIR/review.md"
    ! grep -q "must not look like a heading" "$TEST_DIR/review.md"
}

@test "carry-forward-findings.sh: keeps findings on files the delta left alone, bodies intact" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.carried == 2' > /dev/null
    grep -q "Missing input validation on the forwarded header." "$TEST_DIR/review.md"
    grep -q "Typo in the heading." "$TEST_DIR/review.md"
}

@test "carry-forward-findings.sh: reports carried findings by identity, never by body" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '[.carried_findings[] | keys] | flatten | unique == ["agent", "file", "line"]' > /dev/null
    [[ "$output" != *"Missing input validation"* ]]
}

@test "carry-forward-findings.sh: appends the composed sections after a separator" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --append-file "$TEST_DIR/append.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.appended == true' > /dev/null
    grep -q "^# Re-review at deadbee" "$TEST_DIR/review.md"
    grep -q "^---$" "$TEST_DIR/review.md"
    # the appended section lands after the carried-forward content
    [ "$(grep -n 'Typo in the heading' "$TEST_DIR/review.md" | cut -d: -f1)" -lt \
      "$(grep -n 'Re-review at deadbee' "$TEST_DIR/review.md" | cut -d: -f1)" ]
}

@test "carry-forward-findings.sh: advances the metadata header" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --head-sha bbbbbbb --delta-from aaaaaaa --reviewed-at 2026-08-19T12:00:00Z
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.header_updated == true' > /dev/null
    grep -q "^review_commit: bbbbbbb$" "$TEST_DIR/review.md"
    grep -q "^reviewed_at: 2026-08-19T12:00:00Z$" "$TEST_DIR/review.md"
    grep -q "^review_mode: delta$" "$TEST_DIR/review.md"
    grep -q "^delta_from: aaaaaaa$" "$TEST_DIR/review.md"
    [ "$(grep -c '^review_commit:' "$TEST_DIR/review.md")" -eq 1 ]
}

@test "carry-forward-findings.sh: --dry-run leaves the review file alone" {
    before=$(md5 -q "$TEST_DIR/review.md" 2> /dev/null || md5sum "$TEST_DIR/review.md" | cut -d' ' -f1)
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --append-file "$TEST_DIR/append.md" --head-sha bbbbbbb --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dry_run == true' > /dev/null
    echo "$output" | jq -e '.dropped == 1' > /dev/null
    after=$(md5 -q "$TEST_DIR/review.md" 2> /dev/null || md5sum "$TEST_DIR/review.md" | cut -d' ' -f1)
    [ "$before" = "$after" ]
}

@test "carry-forward-findings.sh: keeps findings it cannot tie to a file" {
    cat > "$TEST_DIR/unattributed.md" << 'EOF'
<!-- review-metadata
review_commit: aaaaaaa
-->

## Security Review

### 1. The rate limiter has no ceiling

Nothing bounds the retry count, so a client can hold the worker open.

#### `src/auth.py:45`

Token comparison is not constant time.
EOF
    run "$SCRIPT" --review-file "$TEST_DIR/unattributed.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.kept_unattributed == 1' > /dev/null
    grep -q "Nothing bounds the retry count" "$TEST_DIR/unattributed.md"
    ! grep -q "Token comparison is not constant time" "$TEST_DIR/unattributed.md"
}

@test "carry-forward-findings.sh: keeps touched findings whose extent is a guess" {
    cat > "$TEST_DIR/location.md" << 'EOF'
<!-- review-metadata
review_commit: aaaaaaa
-->

## Security Review

**Location**: `src/auth.py:45`

Token comparison is not constant time.
EOF
    run "$SCRIPT" --review-file "$TEST_DIR/location.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.kept_undeletable == 1' > /dev/null
    echo "$output" | jq -e '.dropped == 0' > /dev/null
    grep -q "Token comparison is not constant time" "$TEST_DIR/location.md"
}

@test "carry-forward-findings.sh: abandons the cut when the pruned document reparses differently" {
    # The second finding stays open past `## Notes` and takes its file from
    # there. Cutting it hands that line to the first finding, which changes what
    # the first finding is about, so nothing may be cut.
    cat > "$TEST_DIR/leaky.md" << 'EOF'
<!-- review-metadata
review_commit: aaaaaaa
-->

## Security Review

### 1. First finding

Something about the first thing.

**File:** `src/untouched.py`

### 2. Second finding

Something about the second thing.

## Notes

**File:** `src/auth.py`
EOF
    run "$SCRIPT" --review-file "$TEST_DIR/leaky.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pruned == false' > /dev/null
    echo "$output" | jq -e '.prune_reason | test("did not re-parse")' > /dev/null
    grep -q "Something about the second thing." "$TEST_DIR/leaky.md"
}

@test "carry-forward-findings.sh: a second delta round still finds the first round's findings" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --append-file "$TEST_DIR/append.md" --head-sha bbbbbbb --delta-from aaaaaaa
    [ "$status" -eq 0 ]

    cat > "$TEST_DIR/delta2.patch" << 'EOF'
diff --git a/src/untouched.py b/src/untouched.py
--- a/src/untouched.py
+++ b/src/untouched.py
@@ -8,6 +8,7 @@
 unchanged
EOF
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta2.patch" \
        --head-sha ccccccc --delta-from bbbbbbb
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pruned == true' > /dev/null
    # the finding round one appended is attributed and carried, not orphaned
    echo "$output" | jq -e '[.carried_findings[] | select(.file == "src/auth.py" and .line == 47 and .agent == "security")] | length == 1' > /dev/null
    grep -q "the fallback path still leaks length" "$TEST_DIR/review.md"
    ! grep -q "Missing input validation" "$TEST_DIR/review.md"
    grep -q "^review_commit: ccccccc$" "$TEST_DIR/review.md"
}

@test "carry-forward-findings.sh: reports when the delta touches nothing the review flagged" {
    cat > "$TEST_DIR/other.patch" << 'EOF'
diff --git a/src/elsewhere.py b/src/elsewhere.py
--- a/src/elsewhere.py
+++ b/src/elsewhere.py
@@ -1,3 +1,4 @@
 unchanged
EOF
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/other.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dropped == 0' > /dev/null
    echo "$output" | jq -e '.carried == 3' > /dev/null
    echo "$output" | jq -e '.prune_reason == "no findings on the delta'"'"'s files"' > /dev/null
}
