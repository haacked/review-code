#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/update-review-metadata.sh"
    TEST_DIR=$(mktemp -d)
    REVIEW="$TEST_DIR/review with spaces.md"
    REVIEWED_AT="2026-09-16T01:02:03Z"

    cat > "$REVIEW" << 'EOF'
# Existing review

<!-- review-metadata
reviewed_at: 2026-08-01T10:00:00Z
mode: pr
pr_number: 42
review_commit: aaaaaaa
review_mode: delta
delta_from: 1111111
custom_field: retain this value
-->

## Suggested Comments

#### `src/auth.py:45` <!-- pc:123 PRRC_example b:01234567 -->

```text
Validate the token before using it.
```
EOF
    printf '\nClosing note without a final newline' >> "$REVIEW"
    cp "$REVIEW" "$TEST_DIR/before.md"
}

teardown() {
    rm -rf "$TEST_DIR"
}

update_full() {
    "$SCRIPT" --file "$REVIEW" --set review_commit=bbbbbbb \
        --set "reviewed_at=$REVIEWED_AT" --set review_mode=full "$@"
}

assert_rejected_unchanged() {
    [ -x "$SCRIPT" ]
    [ "$status" -ne 0 ]
    cmp -s "$TEST_DIR/before.md" "$REVIEW"
}

@test "update-review-metadata: updates one block in place and preserves surrounding bytes" {
    run update_full
    [ "$status" -eq 0 ]

    python3 - "$TEST_DIR/before.md" "$REVIEW" << 'PY'
from pathlib import Path
import sys

before, after = (Path(path).read_bytes() for path in sys.argv[1:])
expected = before.replace(b"review_commit: aaaaaaa", b"review_commit: bbbbbbb")
expected = expected.replace(b"reviewed_at: 2026-08-01T10:00:00Z", b"reviewed_at: 2026-09-16T01:02:03Z")
expected = expected.replace(b"review_mode: delta", b"review_mode: full")
expected = expected.replace(b"delta_from: 1111111\n", b"")
assert after == expected
PY
}

@test "update-review-metadata: records the new delta baseline" {
    run "$SCRIPT" --file "$REVIEW" --set review_commit=new-sha \
        --set "reviewed_at=$REVIEWED_AT" --set review_mode=delta --set delta_from=previous-sha
    [ "$status" -eq 0 ]
    grep -q '^review_commit: new-sha$' "$REVIEW"
    grep -q '^review_mode: delta$' "$REVIEW"
    grep -q '^delta_from: previous-sha$' "$REVIEW"
    [ "$(grep -c '^delta_from:' "$REVIEW")" -eq 1 ]
}

@test "update-review-metadata: inserts a missing block before the original review" {
    printf '# Review without metadata\n\nKeep this body exactly.' > "$REVIEW"
    cp "$REVIEW" "$TEST_DIR/body.md"

    run update_full
    [ "$status" -eq 0 ]

    python3 - "$TEST_DIR/body.md" "$REVIEW" << 'PY'
from pathlib import Path
import sys

before, after = (Path(path).read_bytes() for path in sys.argv[1:])
assert after.startswith(b"<!-- review-metadata\n")
header, body = after.split(b"-->\n", 1)
assert b"review_commit: bbbbbbb\n" in header
assert b"reviewed_at: 2026-09-16T01:02:03Z\n" in header
assert b"review_mode: full\n" in header
assert body.lstrip(b"\n") == before
PY
}

@test "update-review-metadata: ignores metadata quoted in backtick and tilde fences" {
    cat > "$TEST_DIR/quoted.md" << 'EOF'
````markdown
<!-- review-metadata
review_commit: 1111111
-->
```
````

~~~markdown
<!-- review-metadata
review_commit: 2222222
-->
~~~

EOF
    cat "$TEST_DIR/quoted.md" "$REVIEW" > "$TEST_DIR/combined.md"
    mv "$TEST_DIR/combined.md" "$REVIEW"

    run update_full
    [ "$status" -eq 0 ]

    python3 - "$TEST_DIR/quoted.md" "$REVIEW" << 'PY'
from pathlib import Path
import sys

quoted, after = (Path(path).read_bytes() for path in sys.argv[1:])
assert after.startswith(quoted)
assert b"review_commit: bbbbbbb\n" in after[len(quoted):]
assert b"review_commit: aaaaaaa\n" not in after[len(quoted):]
PY
}

@test "update-review-metadata: inserts a block when every existing block is quoted" {
    cat > "$REVIEW" << 'EOF'
# Metadata example

```markdown
<!-- review-metadata
review_commit: aaaaaaa
-->
```
EOF
    cp "$REVIEW" "$TEST_DIR/body.md"

    run update_full
    [ "$status" -eq 0 ]

    python3 - "$TEST_DIR/body.md" "$REVIEW" << 'PY'
from pathlib import Path
import sys

before, after = (Path(path).read_bytes() for path in sys.argv[1:])
assert after.startswith(b"<!-- review-metadata\n")
assert after.endswith(before)
assert b"review_commit: bbbbbbb\n" in after[:-len(before)]
PY
}

@test "update-review-metadata: rejects duplicate actual blocks without modifying the review" {
    printf '\n\n<!-- review-metadata\nreview_commit: ccccccc\n-->\n' >> "$REVIEW"
    cp "$REVIEW" "$TEST_DIR/before.md"

    run update_full
    assert_rejected_unchanged
}

@test "update-review-metadata: rejects missing required fields without modifying the review" {
    run "$SCRIPT" --file "$REVIEW" --set review_commit=bbbbbbb --set review_mode=full
    assert_rejected_unchanged

    run "$SCRIPT" --file "$REVIEW" --set review_commit=bbbbbbb --set "reviewed_at=$REVIEWED_AT"
    assert_rejected_unchanged
}

@test "update-review-metadata: preserves the commit when it is omitted" {
    run "$SCRIPT" --file "$REVIEW" --set "reviewed_at=$REVIEWED_AT" --set review_mode=full
    [ "$status" -eq 0 ]
    grep -q '^review_commit: aaaaaaa$' "$REVIEW"
    grep -q '^review_mode: full$' "$REVIEW"
    ! grep -q '^delta_from:' "$REVIEW"
}

@test "update-review-metadata: permits non-PR reviews without a commit" {
    printf '# Local review\n' > "$REVIEW"

    run "$SCRIPT" --file "$REVIEW" --set "reviewed_at=$REVIEWED_AT" --set review_mode=full
    [ "$status" -eq 0 ]
    grep -q '^review_mode: full$' "$REVIEW"
    grep -q '^# Local review$' "$REVIEW"
    ! grep -q '^review_commit:' "$REVIEW"
}

@test "update-review-metadata: rejects invalid modes and empty values without modifying the review" {
    run "$SCRIPT" --file "$REVIEW" --set review_commit=bbbbbbb \
        --set "reviewed_at=$REVIEWED_AT" --set review_mode=partial
    assert_rejected_unchanged

    run "$SCRIPT" --file "$REVIEW" --set review_commit= \
        --set "reviewed_at=$REVIEWED_AT" --set review_mode=full
    assert_rejected_unchanged

    run "$SCRIPT" --file "$REVIEW" --set $'review_commit=bbbbbbb\nreview_mode: delta' \
        --set "reviewed_at=$REVIEWED_AT" --set review_mode=full
    assert_rejected_unchanged
}

@test "update-review-metadata: rejects malformed options without modifying the review" {
    run update_full --set missing-equals
    assert_rejected_unchanged

    run update_full --set
    assert_rejected_unchanged

    run update_full --unexpected
    assert_rejected_unchanged
}

@test "update-review-metadata: requires an existing target file" {
    run "$SCRIPT" --set review_commit=bbbbbbb --set "reviewed_at=$REVIEWED_AT" --set review_mode=full
    assert_rejected_unchanged

    run "$SCRIPT" --file "$TEST_DIR/missing.md" --set review_commit=bbbbbbb \
        --set "reviewed_at=$REVIEWED_AT" --set review_mode=full
    assert_rejected_unchanged
    [ ! -e "$TEST_DIR/missing.md" ]
}

@test "update-review-metadata: reads actual fields after fenced metadata without changing the review" {
    cat > "$TEST_DIR/quoted.md" << 'EOF'
````markdown
<!-- review-metadata
review_commit: quoted-backtick-sha
reviewed_at: 2026-01-01T00:00:00Z
-->
```
````

~~~markdown
<!-- review-metadata
review_commit: quoted-tilde-sha
reviewed_at: 2026-02-01T00:00:00Z
-->
~~~

EOF
    cat "$TEST_DIR/quoted.md" "$REVIEW" > "$TEST_DIR/combined.md"
    mv "$TEST_DIR/combined.md" "$REVIEW"
    cp "$REVIEW" "$TEST_DIR/before.md"

    run "$SCRIPT" --file "$REVIEW" --get review_commit
    [ "$status" -eq 0 ]
    [ "$output" = aaaaaaa ]

    run "$SCRIPT" --file "$REVIEW" --get reviewed_at
    [ "$status" -eq 0 ]
    [ "$output" = 2026-08-01T10:00:00Z ]
    cmp -s "$TEST_DIR/before.md" "$REVIEW"
}

@test "update-review-metadata: reads an absent field as empty" {
    printf '<!-- review-metadata\nreviewed_at: 2026-08-01T10:00:00Z\n-->\n' > "$REVIEW"

    run "$SCRIPT" --file "$REVIEW" --get review_commit
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    printf '```markdown\n<!-- review-metadata\nreview_commit: quoted-sha\n-->\n```\n' > "$REVIEW"

    run "$SCRIPT" --file "$REVIEW" --get review_commit
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "update-review-metadata: rejects reads from duplicate actual blocks" {
    run "$SCRIPT" --file "$REVIEW" --get review_commit
    [ "$status" -eq 0 ]
    [ "$output" = aaaaaaa ]

    printf '\n\n<!-- review-metadata\nreview_commit: ccccccc\n-->\n' >> "$REVIEW"
    cp "$REVIEW" "$TEST_DIR/before.md"

    run "$SCRIPT" --file "$REVIEW" --get review_commit
    assert_rejected_unchanged
}

@test "update-review-metadata: rejects repeated fields instead of choosing one value" {
    local key
    for key in review_commit reviewed_at; do
        printf '<!-- review-metadata\n%s: first-value\n%s: second-value\n-->\n' "$key" "$key" > "$REVIEW"
        cp "$REVIEW" "$TEST_DIR/before.md"

        run "$SCRIPT" --file "$REVIEW" --get "$key"
        assert_rejected_unchanged
    done
}

@test "update-review-metadata: rejects a combined read and update without changing the review" {
    run update_full --get review_commit
    assert_rejected_unchanged
}

@test "update-review-metadata: updates and reads an opener with horizontal whitespace" {
    python3 - "$REVIEW" << 'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b"<!-- review-metadata\n", b"<!--\treview-metadata   \n"))
PY

    run update_full
    [ "$status" -eq 0 ]
    [ "$(grep -c 'review-metadata' "$REVIEW")" -eq 1 ]
    grep -q '^review_commit: bbbbbbb$' "$REVIEW"
    ! grep -q '^review_commit: aaaaaaa$' "$REVIEW"

    run "$SCRIPT" --file "$REVIEW" --get review_commit
    [ "$status" -eq 0 ]
    [ "$output" = bbbbbbb ]
}
