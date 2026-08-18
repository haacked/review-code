#!/usr/bin/env bats
# Tests for split-diff-by-path.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/split-diff-by-path.sh"
    DIFF="$BATS_TEST_TMPDIR/in.diff"
    OUT="$BATS_TEST_TMPDIR/out.diff"

    printf '%s\n' \
        'diff --git a/frontend/App.tsx b/frontend/App.tsx' \
        '--- a/frontend/App.tsx' \
        '+++ b/frontend/App.tsx' \
        '@@ -1 +1,2 @@' \
        ' x' \
        '+y' \
        'diff --git a/lib/other.py b/lib/other.py' \
        '--- a/lib/other.py' \
        '+++ b/lib/other.py' \
        '@@ -1 +1,2 @@' \
        ' a' \
        '+b' \
        > "$DIFF"
}

@test "split-diff-by-path: keeps only the requested file" {
    printf '%s\n' 'frontend/App.tsx' | "$SCRIPT" "$DIFF" "$OUT"
    run grep -c '^diff --git' "$OUT"
    [ "$output" -eq 1 ]
    grep -q 'frontend/App.tsx' "$OUT"
}

@test "split-diff-by-path: names the omitted files so the agent knows what it cannot see" {
    printf '%s\n' 'frontend/App.tsx' | "$SCRIPT" "$DIFF" "$OUT"
    grep -q 'Other files changed in this PR' "$OUT"
    grep -q 'lib/other.py' "$OUT"
}

@test "split-diff-by-path: exits non-zero when nothing matches" {
    run bash -c "printf '%s\n' 'absent.ts' | '$SCRIPT' '$DIFF' '$OUT'"
    [ "$status" -ne 0 ]
}

@test "split-diff-by-path: exits non-zero on an empty path list" {
    run bash -c "printf '' | '$SCRIPT' '$DIFF' '$OUT'"
    [ "$status" -ne 0 ]
}

@test "split-diff-by-path: requires both arguments" {
    run "$SCRIPT" "$DIFF"
    [ "$status" -ne 0 ]
}

@test "split-diff-by-path: fails on a missing input diff" {
    run bash -c "printf '%s\n' 'x' | '$SCRIPT' '$BATS_TEST_TMPDIR/nope.diff' '$OUT'"
    [ "$status" -ne 0 ]
}

@test "split-diff-by-path: keeps paths containing spaces" {
    # Taking the last whitespace-separated field of the "diff --git" line
    # truncates such a path, which silently drops the file from the agent's diff
    # and prints a nonexistent path in the trailer.
    printf '%s\n' \
        'diff --git a/my file.txt b/my file.txt' \
        '--- a/my file.txt' \
        '+++ b/my file.txt' \
        '@@ -1 +1 @@' \
        '-a' \
        '+b' \
        > "$DIFF"
    printf '%s\n' 'my file.txt' | "$SCRIPT" "$DIFF" "$OUT"
    grep -q 'my file.txt' "$OUT"
    run grep -c '^diff --git' "$OUT"
    [ "$output" -eq 1 ]
}

@test "split-diff-by-path: reports omitted spaced paths in full" {
    printf '%s\n' \
        'diff --git a/keep.ts b/keep.ts' \
        '--- a/keep.ts' \
        '+++ b/keep.ts' \
        '@@ -1 +1 @@' \
        '-a' \
        '+b' \
        'diff --git a/some dir/skip.py b/some dir/skip.py' \
        '--- a/some dir/skip.py' \
        '+++ b/some dir/skip.py' \
        '@@ -1 +1 @@' \
        '-c' \
        '+d' \
        > "$DIFF"
    printf '%s\n' 'keep.ts' | "$SCRIPT" "$DIFF" "$OUT"
    grep -q 'some dir/skip.py' "$OUT"
}

@test "split-diff-by-path: does not false-match directories containing b" {
    printf '%s\n' \
        'diff --git a/lib/thing.py b/lib/thing.py' \
        '--- a/lib/thing.py' \
        '+++ b/lib/thing.py' \
        '@@ -1 +1 @@' \
        '-a' \
        '+b' \
        > "$DIFF"
    printf '%s\n' 'lib/thing.py' | "$SCRIPT" "$DIFF" "$OUT"
    grep -q 'lib/thing.py' "$OUT"
}

@test "split-diff-by-path: lists omitted files in diff order" {
    printf '%s\n' \
        'diff --git a/keep.ts b/keep.ts' '--- a/keep.ts' '+++ b/keep.ts' '@@ -1 +1 @@' '-a' '+b' \
        'diff --git a/zzz.py b/zzz.py' '--- a/zzz.py' '+++ b/zzz.py' '@@ -1 +1 @@' '-a' '+b' \
        'diff --git a/aaa.py b/aaa.py' '--- a/aaa.py' '+++ b/aaa.py' '@@ -1 +1 @@' '-a' '+b' \
        > "$DIFF"
    printf '%s\n' 'keep.ts' | "$SCRIPT" "$DIFF" "$OUT"
    run grep -A1 'Other files changed' "$OUT"
    [[ "$output" == *"zzz.py, aaa.py"* ]]
}
