#!/usr/bin/env bats
# Tests for review-delta.sh
#
# The dangerous failure here is a real bug shipping because the delta path
# skipped the file holding it, so most of these tests assert that an uncertain
# case falls back to a full review rather than that a delta is produced.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/review-delta.sh"

    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"

    # Signing would prompt; these fixtures only need commit objects.
    export GIT_CONFIG_COUNT=3
    export GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
    export GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=test@example.com
    export GIT_CONFIG_KEY_2=user.name GIT_CONFIG_VALUE_2=Test

    git -C "$REPO" init -q -b main .
    echo base > "$REPO/a.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm base

    git -C "$REPO" checkout -qb feature
    for i in 1 2 3 4; do echo "x$i" > "$REPO/f$i.txt"; done
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "four files"
    REVIEWED_SHA=$(git -C "$REPO" rev-parse HEAD)

    echo fix >> "$REPO/f1.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "small fix"
    HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
}

mode_of() { echo "$1" | jq -r '.mode'; }

# =============================================================================
# Structure and arguments
# =============================================================================

@test "review-delta: has correct shebang" {
    run head -1 "$SCRIPT"
    [ "$output" = "#!/usr/bin/env bash" ]
}

@test "review-delta: uses set -euo pipefail" {
    run grep -q 'set -euo pipefail' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "review-delta: requires --head-sha" {
    run "$SCRIPT" --review-commit abc123
    [ "$status" -ne 0 ]
}

@test "review-delta: rejects unknown arguments" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --nonsense
    [ "$status" -ne 0 ]
}

@test "review-delta: requires --base" {
    # Deriving the base would silently produce a full review on a stacked PR,
    # which is the failure this script exists to avoid.
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q -- "--base is required"
}

@test "review-delta: emits valid JSON" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base main
    echo "$output" | jq -e . > /dev/null
}

# =============================================================================
# The delta path
# =============================================================================

@test "review-delta: returns delta when one of four files changed" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "delta" ]
    [ "$(echo "$output" | jq -r '.changed_files')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.pr_files')" -eq 4 ]
}

@test "review-delta: writes the delta diff to the named path" {
    local out="$BATS_TEST_TMPDIR/delta.patch"
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base main --out "$out"
    [ -s "$out" ]
    grep -q "f1.txt" "$out"
}

@test "review-delta: the delta holds only what changed since the review" {
    local out="$BATS_TEST_TMPDIR/delta.patch"
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base main --out "$out"
    run grep -c '^diff --git' "$out"
    [ "$output" -eq 1 ]
}

@test "review-delta: reports the SHA the delta was taken from" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base main
    [ "$(echo "$output" | jq -r '.delta_from')" = "$REVIEWED_SHA" ]
}

# =============================================================================
# No-change
# =============================================================================

@test "review-delta: reports no change when review_commit equals head" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$HEAD_SHA" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "no-change" ]
    echo "$output" | jq -r '.reason' | grep -q "no change"
}

# =============================================================================
# Fallbacks to a full review, each of which must say why
# =============================================================================

@test "review-delta: falls back to full when no review_commit is recorded" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "full" ]
}

@test "review-delta: falls back to full when review_commit is unknown to the repo" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "full" ]
}

@test "review-delta: falls back to full when review_commit is not an ancestor of head" {
    git -C "$REPO" checkout -q -b divergent main
    echo z > "$REPO/z.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm divergent
    local other; other=$(git -C "$REPO" rev-parse HEAD)
    git -C "$REPO" checkout -q feature

    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$other" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "full" ]
    echo "$output" | jq -r '.reason' | grep -qi "ancestor"
}

@test "review-delta: falls back to full when the base moved under the PR" {
    # Merging main into the branch between reviews keeps ancestry intact, so
    # this reaches the merge-base guard rather than exiting at the ancestor
    # check one branch earlier.
    git -C "$REPO" checkout -q main
    echo newer > "$REPO/newer.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "base advances"
    git -C "$REPO" checkout -q feature
    git -C "$REPO" merge -q --no-ff -m "merge main" main
    echo more >> "$REPO/f2.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "after merge"
    local merged_head; merged_head=$(git -C "$REPO" rev-parse HEAD)

    run "$SCRIPT" --head-sha "$merged_head" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "full" ]
    echo "$output" | jq -r '.reason' | grep -qi "base moved"
}

@test "review-delta: resolves a base that exists only as a remote-tracking ref" {
    # A PR stacked on someone else's branch, or based on a release branch the
    # user never checked out, has the base only under refs/remotes.
    git -C "$REPO" update-ref refs/remotes/origin/release main
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base release
    [ "$(mode_of "$output")" = "delta" ]
}

@test "review-delta: falls back to full when the base is nowhere in the repo" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base no-such-branch
    [ "$(mode_of "$output")" = "full" ]
    echo "$output" | jq -r '.reason' | grep -qi "could not be resolved"
}

@test "review-delta: falls back to full when a rebase rewrote the reviewed commit" {
    echo moved > "$REPO/m.txt"
    git -C "$REPO" checkout -q main
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "base moves"
    git -C "$REPO" checkout -q feature
    git -C "$REPO" rebase -q main
    local rebased; rebased=$(git -C "$REPO" rev-parse HEAD)

    run "$SCRIPT" --head-sha "$rebased" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "full" ]
}

@test "review-delta: falls back to full when the delta covers more than half the PR" {
    local base_sha; base_sha=$(git -C "$REPO" rev-parse main)
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$base_sha" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "full" ]
    echo "$output" | jq -r '.reason' | grep -q "threshold"
}

@test "review-delta: honors a custom --max-fraction" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base main --max-fraction 0.1
    [ "$(mode_of "$output")" = "full" ]
}

@test "review-delta: falls back to full when the repo directory is missing" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$BATS_TEST_TMPDIR/nope" --base main
    [ "$(mode_of "$output")" = "full" ]
}

@test "review-delta: falls back to full outside a git repository" {
    mkdir -p "$BATS_TEST_TMPDIR/plain"
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$BATS_TEST_TMPDIR/plain" --base main
    [ "$(mode_of "$output")" = "full" ]
}

@test "review-delta: falls back to full when the base cannot be resolved" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit "$REVIEWED_SHA" --repo-dir "$REPO" --base no-such-branch
    [ "$(mode_of "$output")" = "full" ]
}

@test "review-delta: every fallback states a reason" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --repo-dir "$REPO" --base main
    [ -n "$(echo "$output" | jq -r '.reason')" ]
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --repo-dir "$REPO" --base main
    [ -n "$(echo "$output" | jq -r '.reason')" ]
}

# =============================================================================
# Recovering the SHA from the review document
# =============================================================================

@test "review-delta: reads review_commit from a review file's metadata header" {
    local rf="$BATS_TEST_TMPDIR/pr-1.md"
    printf '<!-- review-metadata\nreviewed_at: 2026-08-18T00:00:00Z\nreview_commit: %s\n-->\n' "$REVIEWED_SHA" > "$rf"
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-file "$rf" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "delta" ]
    [ "$(echo "$output" | jq -r '.delta_from')" = "$REVIEWED_SHA" ]
}

@test "review-delta: falls back to full when the review file has no review_commit" {
    local rf="$BATS_TEST_TMPDIR/pr-2.md"
    printf '<!-- review-metadata\nreviewed_at: 2026-08-18T00:00:00Z\n-->\n' > "$rf"
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-file "$rf" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "full" ]
}

@test "review-delta: falls back to full when the review file does not exist" {
    run "$SCRIPT" --head-sha "$HEAD_SHA" --review-file "$BATS_TEST_TMPDIR/absent.md" --repo-dir "$REPO" --base main
    [ "$(mode_of "$output")" = "full" ]
}
