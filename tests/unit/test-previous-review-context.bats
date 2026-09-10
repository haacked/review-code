#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$ROOT/skills/review-code/scripts/previous-review-context.py"
    REVIEW="$BATS_TEST_TMPDIR/review.md"
    DIFF="$BATS_TEST_TMPDIR/delta.patch"
    ARCH="$BATS_TEST_TMPDIR/arch.md"
    OUT="$BATS_TEST_TMPDIR/out"
    mkdir -p "$OUT"
    echo "No additional dependencies." > "$ARCH"
    printf 'diff --git a/src/changed.py b/src/changed.py\n--- a/src/changed.py\n+++ b/src/changed.py\n' > "$DIFF"
    long="$(printf 'detail %.0s' {1..900})"
    cat > "$REVIEW" <<REVIEW
# Review

#### \`src/changed.py:12\` <!-- pc:123 NODE b:abcd -->

\`\`\`text
[P1] Changed concern
Changed detail.
\`\`\`
Location: src/changed.py:12 | Confidence: 95%

#### \`src/quiet.py:8\`

\`\`\`text
[P2] Quiet concern
$long QUIET_END
\`\`\`
Location: src/quiet.py:8 | Confidence: 90%

#### \`src/dependent.py:3\`

\`\`\`text
[P1] Dependency concern
Calls src/changed.py.
\`\`\`
Location: src/dependent.py:3 | Confidence: 95%

#### \`src/withdrawn.py:5\`

\`\`\`text
[P2] Withdrawn concern
The input appeared unchecked.
\`\`\`
*Withdrawn 2026-08-25: The caller already validates it.*
REVIEW
}

build() {
    python3 "$SCRIPT" build --review "$REVIEW" --diff "$DIFF" --output-dir "$OUT" --arch-context "$ARCH"
}

@test "indexes all findings and retains touched dependencies and withdrawals" {
    run build
    [ "$status" -eq 0 ]
    [[ "$output" == *"Changed detail"* ]]
    [[ "$output" == *"Calls src/changed.py"* ]]
    [[ "$output" == *"caller already validates"* ]]
    [[ "$output" != *"QUIET_END"* ]]
    jq -e '.findings | length == 4' "$OUT/previous-review/index.json"
    jq -e '.findings[] | select(.path == "src/quiet.py") | .full == false' "$OUT/previous-review/index.json"
}

@test "retrieves exact annotated finding under an untrusted warning" {
    build >/dev/null
    run python3 "$SCRIPT" get --output-dir "$OUT" --id pc-123
    [ "$status" -eq 0 ]
    [[ "$output" == Previous\ review\ material* ]]
    [[ "$output" == *'<!-- pc:123 NODE b:abcd -->'* ]]
    [[ "$output" != *"QUIET_END"* ]]
}

@test "architectural path retains a complete finding" {
    echo "src/quiet.py consumes the changed API." > "$ARCH"
    run build
    [ "$status" -eq 0 ]
    [[ "$output" == *"QUIET_END"* ]]
}

@test "missing scope context and malformed inputs preserve the full review" {
    run python3 "$SCRIPT" build --review "$REVIEW" --diff "$DIFF" --output-dir "$OUT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"QUIET_END"* ]]
    echo "invalid" > "$DIFF"
    run build
    [ "$status" -eq 0 ]
    [[ "$output" == *"QUIET_END"* ]]
}

@test "unposted identifiers survive unrelated fenced headings" {
    build >/dev/null
    id="$(jq -r '.findings[] | select(.path == "src/quiet.py") | .id' "$OUT/previous-review/index.json")"
    cat >> "$REVIEW" <<'REVIEW'

```markdown
#### `src/fake.py:99`
```
REVIEW
    build >/dev/null
    [ "$id" = "$(jq -r '.findings[] | select(.path == "src/quiet.py") | .id' "$OUT/previous-review/index.json")" ]
    jq -e '[.findings[] | select(.path == "src/fake.py")] | length == 0' "$OUT/previous-review/index.json"
}

@test "duplicate posted IDs produce distinct retrieval artifacts" {
    cat >> "$REVIEW" <<'REVIEW'

#### `src/copy.py:4` <!-- pc:123 NODE b:def -->

```text
[P2] Suggested-comment copy
Another rendering of the posted finding.
```
REVIEW
    build >/dev/null
    jq -e '[.findings[] | select(.id | startswith("pc-123-"))] | length == 2' "$OUT/previous-review/index.json"
    mapfile -t ids < <(jq -r '.findings[] | select(.id | startswith("pc-123-")) | .id' "$OUT/previous-review/index.json")
    [ "${ids[0]}" != "${ids[1]}" ]
    run python3 "$SCRIPT" get --output-dir "$OUT" --id "${ids[0]}"
    [ "$status" -eq 0 ]
    first="$output"
    run python3 "$SCRIPT" get --output-dir "$OUT" --id "${ids[1]}"
    [ "$status" -eq 0 ]
    second="$output"
    [[ "$first$second" == *"Changed detail"* ]]
    [[ "$first$second" == *"Another rendering"* ]]
}

@test "status markers outside fences retain full reasons and quoted markers do not" {
    cat >> "$REVIEW" <<'REVIEW'

#### `src/resolved.py:4`

```text
[P2] Resolved concern
This is fixed.
```
*Resolved 2026-09-05: The caller now validates it.*

#### `src/example.py:5`

```text
[P3] Documentation example
*Withdrawn 2026-09-05: This is quoted example text.*
```
REVIEW
    build >/dev/null
    jq -e '.findings[] | select(.path == "src/resolved.py") | .status == "resolved" and .full' "$OUT/previous-review/index.json"
    jq -e '.findings[] | select(.path == "src/example.py") | .status == "recorded (recheck)"' "$OUT/previous-review/index.json"
}

@test "rename diffs retain findings on the source path" {
    cat > "$DIFF" <<'PATCH'
diff --git a/src/quiet.py b/src/renamed.py
similarity index 100%
rename from src/quiet.py
rename to src/renamed.py
PATCH
    run build
    [ "$status" -eq 0 ]
    [[ "$output" == *"QUIET_END"* ]]
}

@test "small reviews fall back when indexing would add bytes" {
    cat > "$REVIEW" <<'REVIEW'
#### `src/quiet.py:1`

```text
[P3] Small concern
One line.
```
REVIEW
    run build
    [ "$status" -eq 0 ]
    [[ "$output" == *"One line."* ]]
    jq -e '.fallback == true and (.findings | all(.full))' "$OUT/previous-review/index.json"
}

@test "unknown retrieval ID fails without unrelated content" {
    build >/dev/null
    run python3 "$SCRIPT" get --output-dir "$OUT" --id missing
    [ "$status" -ne 0 ]
    [[ "$output" != *"Changed detail"* ]]
}
