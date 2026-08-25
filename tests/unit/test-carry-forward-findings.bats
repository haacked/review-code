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

@test "carry-forward-findings.sh: reports counts, never finding bodies" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]
    # stdout lands in the orchestrator's conversation, so it stays small: counts,
    # flags, and the cut files, with no per-finding array and no bodies.
    [[ "$output" != *"Missing input validation"* ]]
    [[ "$output" != *"constant time"* ]]
    echo "$output" | jq -e 'has("carried_findings") | not' > /dev/null
    echo "$output" | jq -e '[paths(type == "array") ] | length == 1' > /dev/null
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
        --head-sha bbbbbbb --delta-from aaaaaaa
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.header_updated == true' > /dev/null
    grep -q "^review_commit: bbbbbbb$" "$TEST_DIR/review.md"
    grep -qE '^reviewed_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$TEST_DIR/review.md"
    grep -q "^review_mode: delta$" "$TEST_DIR/review.md"
    grep -q "^delta_from: aaaaaaa$" "$TEST_DIR/review.md"
    [ "$(grep -c '^review_commit:' "$TEST_DIR/review.md")" -eq 1 ]
}

@test "carry-forward-findings.sh: --dry-run leaves the review file alone" {
    cp "$TEST_DIR/review.md" "$TEST_DIR/before.md"
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --append-file "$TEST_DIR/append.md" --head-sha bbbbbbb --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.dry_run == true' > /dev/null
    echo "$output" | jq -e '.dropped == 1' > /dev/null
    cmp -s "$TEST_DIR/before.md" "$TEST_DIR/review.md"
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
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '[.[] | select(.file == "src/auth.py" and .line == 47 and .agent == "security")] | length == 1' > /dev/null
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

@test "carry-forward-findings.sh: a pure rename counts as a touched file" {
    # git writes no ---/+++ lines for a rename with no content change, so the
    # delta's files come from the "diff --git a/OLD b/NEW" header, both sides:
    # a finding recorded before the rename cites the old path.
    cat > "$TEST_DIR/rename.patch" << 'EOF'
diff --git a/src/auth.py b/src/authentication.py
similarity index 100%
rename from src/auth.py
rename to src/authentication.py
EOF
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/rename.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.delta_files == 2' > /dev/null
    echo "$output" | jq -e '.dropped == 1' > /dev/null
    echo "$output" | jq -e '.dropped_files == ["src/auth.py"]' > /dev/null
    ! grep -q "constant time" "$TEST_DIR/review.md"
    grep -q "Missing input validation" "$TEST_DIR/review.md"
}

# The withdrawal marker's literal form is the contract parse-review-findings.sh
# matches on, so it lives in one place here rather than in each test.
withdraw_untouched_finding() {
    python3 - "$TEST_DIR/review.md" "$1" << 'PY'
import sys
path, reason = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
for i, line in enumerate(lines):
    if line.startswith("#### `src/untouched.py"):
        lines[i + 1:i + 1] = ["", f"*Withdrawn 2026-08-25: {reason}*"]
        break
open(path, "w").write("\n".join(lines) + "\n")
PY
}

# =============================================================================
# Withdrawn findings
# =============================================================================

# A finding the author argued down must not come back on the next re-review,
# and its text must survive so the argument stays on the record.
@test "carry-forward-findings.sh: does not carry a withdrawn finding forward as live" {
    # Retire the finding on a file the delta does not touch, so the only thing
    # that can keep it out of the carried set is the withdrawal marker.
    withdraw_untouched_finding "author showed the header is validated upstream"
    carried_before=$("$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" \
        --include-withdrawn "$TEST_DIR/review.md" | jq '[.[] | select(.withdrawn)] | length')
    [ "$carried_before" -eq 1 ]

    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]

    # Still in the document, but no longer a finding anything will act on.
    grep -q "Missing input validation on the forwarded header." "$TEST_DIR/review.md"
    live=$("$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md" \
        | jq '[.[] | select(.file == "src/untouched.py")] | length')
    [ "$live" -eq 0 ]
}

@test "carry-forward-findings.sh: prune-safety still passes with a withdrawal marker present" {
    withdraw_untouched_finding "not a real issue"
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pruned == true' > /dev/null
}
