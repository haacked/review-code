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

@test "carry-forward-findings.sh: creates missing metadata when advancing the review" {
    sed '1,/^-->$/d' "$TEST_DIR/review.md" > "$TEST_DIR/no-header.md"

    run "$SCRIPT" --review-file "$TEST_DIR/no-header.md" --delta-diff "$TEST_DIR/delta.patch" \
        --head-sha bbbbbbb --delta-from aaaaaaa
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.header_updated == true' > /dev/null
    [ "$(head -n 1 "$TEST_DIR/no-header.md")" = '<!-- review-metadata' ]
    grep -q '^review_commit: bbbbbbb$' "$TEST_DIR/no-header.md"
    grep -q '^review_mode: delta$' "$TEST_DIR/no-header.md"
    grep -q '^delta_from: aaaaaaa$' "$TEST_DIR/no-header.md"
    grep -q 'Missing input validation on the forwarded header.' "$TEST_DIR/no-header.md"
}

@test "carry-forward-findings.sh: advances real metadata without changing a fenced example" {
    cat > "$TEST_DIR/quoted.md" << 'EOF'
```markdown
<!-- review-metadata
review_commit: 1111111
-->
```

EOF
    cat "$TEST_DIR/quoted.md" "$TEST_DIR/review.md" > "$TEST_DIR/combined.md"
    mv "$TEST_DIR/combined.md" "$TEST_DIR/review.md"

    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --head-sha bbbbbbb --delta-from aaaaaaa
    [ "$status" -eq 0 ]

    python3 - "$TEST_DIR/quoted.md" "$TEST_DIR/review.md" << 'PY'
from pathlib import Path
import sys

quoted, after = (Path(path).read_bytes() for path in sys.argv[1:])
assert after.startswith(quoted)
assert b"review_commit: bbbbbbb\n" in after[len(quoted):]
assert b"review_commit: aaaaaaa\n" not in after[len(quoted):]
PY
}

@test "carry-forward-findings.sh: duplicate metadata prevents pruning or appending" {
    printf '\n<!-- review-metadata\nreview_commit: ccccccc\n-->\n' >> "$TEST_DIR/review.md"
    cp "$TEST_DIR/review.md" "$TEST_DIR/before.md"

    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --append-file "$TEST_DIR/append.md" --head-sha bbbbbbb --delta-from aaaaaaa
    [ "$status" -ne 0 ]
    cmp -s "$TEST_DIR/before.md" "$TEST_DIR/review.md"
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
    echo "$output" | jq -e '.prune_reason == "no findings to replace on the delta'"'"'s files"' > /dev/null
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

# =============================================================================
# Prune safety across long finding bodies
# =============================================================================

# The check that guards the cut compares the expected survivors against a
# re-parse of the pruned file. Both sides have to be parsed the same way: the
# plain mode truncates a description at 500 bytes and the --with-spans mode does
# not, so on any review with a finding body past that length the two can never
# match and the cut is abandoned every time. Real reviews run to thousands of
# characters per finding, so this is the normal case, not an edge one.
@test "carry-forward-findings.sh: prunes a review whose findings exceed the truncation limit" {
    local long_body
    long_body=$(printf 'The token comparison leaks timing information. %.0s' {1..20})
    [ "${#long_body}" -gt 500 ]

    cat > "$TEST_DIR/long.md" << EOF
<!-- review-metadata
reviewed_at: 2026-08-01T10:00:00Z
mode: pr
pr_number: 42
review_commit: aaaaaaa
-->

# Pull Request Review: #42

## Security Review

#### \`src/auth.py:45\`

${long_body}

---

#### \`src/untouched.py:10\`

${long_body}

---
EOF

    run "$SCRIPT" --review-file "$TEST_DIR/long.md" --delta-diff "$TEST_DIR/delta.patch"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.pruned == true' > /dev/null
    echo "$output" | jq -e '.dropped == 1' > /dev/null
    echo "$output" | jq -e '.carried == 1' > /dev/null
    # The delta touched src/auth.py, so that finding goes and the other stays.
    ! grep -q 'src/auth.py:45' "$TEST_DIR/long.md"
    grep -q 'src/untouched.py:10' "$TEST_DIR/long.md"
}

@test "carry-forward-findings.sh: preserves touched findings from reviewers omitted by the delta" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --reviewed-agents 'testing correctness maintainability'
    [ "$status" -eq 0 ]
    jq -e '.dropped == 0 and .carried == 3 and .dropped_files == []' <<< "$output"
    grep -q "Token comparison is not constant time" "$TEST_DIR/review.md"
    grep -q "must not look like a heading" "$TEST_DIR/review.md"
    grep -q "Missing input validation on the forwarded header" "$TEST_DIR/review.md"
}

@test "carry-forward-findings.sh: prunes only rerun reviewers on a file with several findings" {
    cat >> "$TEST_DIR/review.md" <<'EOF'

## Testing Review

#### `src/auth.py:46`

The fallback branch has no regression test.

## Correctness Review

#### `src/auth.py:47`

The fallback branch compares the wrong token.
EOF

    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --reviewed-agents 'testing correctness'
    [ "$status" -eq 0 ]
    jq -e '.pruned == true and .dropped == 2 and .carried == 3 and .dropped_files == ["src/auth.py"]' <<< "$output"
    grep -q "Token comparison is not constant time" "$TEST_DIR/review.md"
    ! grep -q "The fallback branch has no regression test" "$TEST_DIR/review.md"
    ! grep -q "The fallback branch compares the wrong token" "$TEST_DIR/review.md"
    grep -q "Missing input validation on the forwarded header" "$TEST_DIR/review.md"
    grep -q "Typo in the heading" "$TEST_DIR/review.md"
}

@test "carry-forward-findings.sh: rerun reviewer still preserves its untouched findings" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --reviewed-agents security
    [ "$status" -eq 0 ]
    jq -e '.pruned == true and .dropped == 1 and .carried == 2' <<< "$output"
    ! grep -q "Token comparison is not constant time" "$TEST_DIR/review.md"
    grep -q "Missing input validation on the forwarded header" "$TEST_DIR/review.md"
}

@test "carry-forward-findings.sh: an explicit empty reviewer set preserves every finding" {
    run "$SCRIPT" --review-file "$TEST_DIR/review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --reviewed-agents ''
    [ "$status" -eq 0 ]
    jq -e '.dropped == 0 and .carried == 3' <<< "$output"
    grep -q "Token comparison is not constant time" "$TEST_DIR/review.md"
    grep -q "Missing input validation on the forwarded header" "$TEST_DIR/review.md"
    grep -q "Typo in the heading" "$TEST_DIR/review.md"
}

@test "carry-forward-findings.sh: unknown reviewer attribution is retained when selection is explicit" {
    cat > "$TEST_DIR/unknown.md" <<'EOF'
#### `src/auth.py:45`

The authentication fallback bypasses validation.
EOF

    run "$SCRIPT" --review-file "$TEST_DIR/unknown.md" --delta-diff "$TEST_DIR/delta.patch" \
        --reviewed-agents 'security correctness testing'
    [ "$status" -eq 0 ]
    jq -e '.dropped == 0 and .carried == 1' <<< "$output"
    grep -q "The authentication fallback bypasses validation" "$TEST_DIR/unknown.md"
}

create_infra_findings() {
    cat > "$TEST_DIR/infra-review.md" <<'EOF'
## Security Review

#### `terraform/main.tf:2`

The policy permits access from every external network.

## Infra-Config Review

#### `terraform/main.tf:5`

The service references a missing production subnet.
EOF
    cat > "$TEST_DIR/infra.patch" <<'EOF'
diff --git a/terraform/main.tf b/terraform/main.tf
--- a/terraform/main.tf
+++ b/terraform/main.tf
@@ -1 +1 @@
-old configuration
+new configuration
EOF
}

@test "carry-forward-findings.sh: a security rerun preserves touched infra findings after its section" {
    create_infra_findings

    run "$SCRIPT" --review-file "$TEST_DIR/infra-review.md" --delta-diff "$TEST_DIR/infra.patch" \
        --reviewed-agents security
    [ "$status" -eq 0 ]
    jq -e '.pruned == true and .dropped == 1 and .carried == 1' <<< "$output"
    ! grep -q "The policy permits access from every external network" "$TEST_DIR/infra-review.md"
    grep -q "The service references a missing production subnet" "$TEST_DIR/infra-review.md"
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/infra-review.md"
    [ "$status" -eq 0 ]
    jq -e 'length == 1 and .[0].agent == "infra-config"' <<< "$output"
}

@test "carry-forward-findings.sh: an infra rerun prunes its finding without pruning security" {
    create_infra_findings

    run "$SCRIPT" --review-file "$TEST_DIR/infra-review.md" --delta-diff "$TEST_DIR/infra.patch" \
        --reviewed-agents infra-config
    [ "$status" -eq 0 ]
    jq -e '.pruned == true and .dropped == 1 and .carried == 1' <<< "$output"
    grep -q "The policy permits access from every external network" "$TEST_DIR/infra-review.md"
    ! grep -q "The service references a missing production subnet" "$TEST_DIR/infra-review.md"
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/infra-review.md"
    [ "$status" -eq 0 ]
    jq -e 'length == 1 and .[0].agent == "security"' <<< "$output"
}

create_suggested_comments() {
    cat > "$TEST_DIR/suggested-review.md" <<'EOF'
## Security Review

#### `src/auth.py:45`

The token comparison leaks timing information.

## Testing Review

#### `src/auth.py:46`

The fallback branch lacks a regression test.

---

## Suggested Comments

These suggestions are for posting as inline PR review comments.

### New Comments

#### `src/auth.py:45`

```text
Use a constant-time comparison to prevent the token timing leak.
```

*From: Security (95% confidence)*

---

### Build Upon Existing

#### `src/auth.py:46`

**Existing comment by @reviewer:**
> Add coverage for authentication errors.

**Add to discussion:**

```text
Add a regression test that exercises the fallback branch.
```

*From: Testing (90% confidence)*
EOF
}

@test "carry-forward-findings.sh: security rerun prunes its suggested comment by From attribution" {
    create_suggested_comments

    run "$SCRIPT" --review-file "$TEST_DIR/suggested-review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --reviewed-agents security
    [ "$status" -eq 0 ]
    jq -e '.pruned == true and .dropped == 2 and .carried == 2' <<< "$output"
    ! grep -q "The token comparison leaks timing information" "$TEST_DIR/suggested-review.md"
    ! grep -q "Use a constant-time comparison to prevent the token timing leak" "$TEST_DIR/suggested-review.md"
    grep -q "The fallback branch lacks a regression test" "$TEST_DIR/suggested-review.md"
    grep -q "Add a regression test that exercises the fallback branch" "$TEST_DIR/suggested-review.md"
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/suggested-review.md"
    [ "$status" -eq 0 ]
    jq -e 'length == 2 and all(.[]; .agent == "testing")' <<< "$output"
}

@test "carry-forward-findings.sh: testing rerun preserves security suggestions after its section" {
    create_suggested_comments

    run "$SCRIPT" --review-file "$TEST_DIR/suggested-review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --reviewed-agents testing
    [ "$status" -eq 0 ]
    jq -e '.pruned == true and .dropped == 2 and .carried == 2' <<< "$output"
    grep -q "The token comparison leaks timing information" "$TEST_DIR/suggested-review.md"
    grep -q "Use a constant-time comparison to prevent the token timing leak" "$TEST_DIR/suggested-review.md"
    ! grep -q "The fallback branch lacks a regression test" "$TEST_DIR/suggested-review.md"
    ! grep -q "Add a regression test that exercises the fallback branch" "$TEST_DIR/suggested-review.md"
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/suggested-review.md"
    [ "$status" -eq 0 ]
    jq -e 'length == 2 and all(.[]; .agent == "security")' <<< "$output"
}

@test "carry-forward-findings.sh: suggestions with unknown or missing attribution do not inherit preceding reviewer" {
    create_suggested_comments
    cat >> "$TEST_DIR/suggested-review.md" <<'EOF'

---

#### `src/auth.py:47`

```text
The retry loop can keep the authentication worker occupied.
```

*From: Unrecognized (95% confidence)*

---

#### `src/auth.py:48`

```text
The empty token reaches the privileged fallback path.
```
EOF

    run "$SCRIPT" --review-file "$TEST_DIR/suggested-review.md" --delta-diff "$TEST_DIR/delta.patch" \
        --reviewed-agents testing
    [ "$status" -eq 0 ]
    jq -e '.pruned == true and .dropped == 2 and .carried == 4' <<< "$output"
    grep -q "The retry loop can keep the authentication worker occupied" "$TEST_DIR/suggested-review.md"
    grep -q "The empty token reaches the privileged fallback path" "$TEST_DIR/suggested-review.md"
    ! grep -q "The fallback branch lacks a regression test" "$TEST_DIR/suggested-review.md"
    ! grep -q "Add a regression test that exercises the fallback branch" "$TEST_DIR/suggested-review.md"
}
