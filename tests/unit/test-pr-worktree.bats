#!/usr/bin/env bats
# Tests for scripts/pr-worktree.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/pr-worktree.sh"
    export PROJECT_ROOT SCRIPT

    TEST_DIR=$(mktemp -d)
    BARE_ORIGIN="$TEST_DIR/origin.git"
    CLONE_DIR="$TEST_DIR/clone"
    WORKTREE_ROOT="$TEST_DIR/worktrees"

    git init --bare --quiet "$BARE_ORIGIN"

    # Seed the bare origin with a commit on main and a PR ref.
    local seed="$TEST_DIR/seed"
    git init --quiet "$seed"
    git -C "$seed" config commit.gpgsign false
    git -C "$seed" config user.email "test@example.com"
    git -C "$seed" config user.name "Test User"
    echo "hello" > "$seed/file.txt"
    git -C "$seed" add file.txt
    git -C "$seed" commit --quiet -m "initial"
    git -C "$seed" branch -M main
    git -C "$seed" remote add origin "$BARE_ORIGIN"
    git -C "$seed" push --quiet origin main

    # Simulate a PR: a second commit pushed to refs/pull/42/head
    echo "world" >> "$seed/file.txt"
    git -C "$seed" commit --quiet -am "pr commit"
    git -C "$seed" push --quiet origin "HEAD:refs/pull/42/head"
    rm -rf "$seed"

    # The user's local clone of the origin.
    git clone --quiet "$BARE_ORIGIN" "$CLONE_DIR"
    git -C "$CLONE_DIR" config commit.gpgsign false
    git -C "$CLONE_DIR" config user.email "test@example.com"
    git -C "$CLONE_DIR" config user.name "Test User"

    export REVIEW_CODE_WORKTREE_DIR="$WORKTREE_ROOT"
    export TEST_DIR BARE_ORIGIN CLONE_DIR WORKTREE_ROOT
}

teardown() {
    # Best-effort cleanup: remove any registered worktrees first, then the tmp.
    if [[ -d "$CLONE_DIR" ]]; then
        git -C "$CLONE_DIR" worktree list --porcelain 2> /dev/null \
            | awk '/^worktree / { print substr($0, 10) }' \
            | while read -r wt; do
                [[ "$wt" = "$CLONE_DIR" ]] && continue
                git -C "$CLONE_DIR" worktree remove --force "$wt" > /dev/null 2>&1 || true
            done
    fi
    rm -rf "$TEST_DIR"
}

# =============================================================================
# provision
# =============================================================================

@test "pr-worktree provision: creates worktree and outputs JSON" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>/dev/null" _ myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]

    # Output is valid JSON with both fields.
    echo "$output" | jq -e '.worktree_path and .ref' > /dev/null

    local wt_path
    wt_path=$(echo "$output" | jq -r '.worktree_path')
    local ref
    ref=$(echo "$output" | jq -r '.ref')

    [ "$ref" = "refs/review-code/pr/42" ]
    [ -d "$wt_path" ]
    [ -f "$wt_path/file.txt" ]

    # Ref is registered in the clone.
    run git -C "$CLONE_DIR" rev-parse --verify "$ref"
    [ "$status" -eq 0 ]

    # Worktree is registered.
    run git -C "$CLONE_DIR" worktree list --porcelain
    [[ "$output" == *"$wt_path"* ]]
}

@test "pr-worktree provision: is idempotent on second invocation" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>/dev/null" _ myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
    local first_path
    first_path=$(echo "$output" | jq -r '.worktree_path')

    run bash -c "'$SCRIPT' provision \"\$@\" 2>/dev/null" _ myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
    local second_path
    second_path=$(echo "$output" | jq -r '.worktree_path')

    [ "$first_path" = "$second_path" ]
    [ -d "$second_path" ]
}

@test "pr-worktree provision: rejects non-numeric PR number" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>&1" _ myorg myrepo notanumber "$CLONE_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid PR number"* ]]
}

@test "pr-worktree provision: rejects non-git-repo local clone" {
    local bogus="$TEST_DIR/not-a-repo"
    mkdir -p "$bogus"
    run bash -c "'$SCRIPT' provision \"\$@\" 2>&1" _ myorg myrepo 42 "$bogus"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not a git repo"* ]]
}

@test "pr-worktree provision: fails when PR ref is absent from origin" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>&1" _ myorg myrepo 999 "$CLONE_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Fetch failed"* ]]
}

@test "pr-worktree provision: rejects org with path traversal" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>&1" _ ".." myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid org"* ]]
}

@test "pr-worktree provision: rejects repo with slashes" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>&1" _ myorg "bad/repo" 42 "$CLONE_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid repo"* ]]
}

@test "pr-worktree provision: updates worktree when PR ref moves" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>/dev/null" _ myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
    local wt_path
    wt_path=$(echo "$output" | jq -r '.worktree_path')

    # Author pushes a new commit to refs/pull/42/head.
    local seed2="$TEST_DIR/seed2"
    git clone --quiet "$BARE_ORIGIN" "$seed2"
    git -C "$seed2" config commit.gpgsign false
    git -C "$seed2" config user.email "test@example.com"
    git -C "$seed2" config user.name "Test User"
    git -C "$seed2" fetch --quiet origin "refs/pull/42/head:pr42"
    git -C "$seed2" checkout --quiet pr42
    echo "newer" >> "$seed2/file.txt"
    git -C "$seed2" commit --quiet -am "second pr commit"
    git -C "$seed2" push --quiet origin "HEAD:refs/pull/42/head"
    rm -rf "$seed2"

    run bash -c "'$SCRIPT' provision \"\$@\" 2>/dev/null" _ myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
    grep -q "newer" "$wt_path/file.txt"
}

@test "pr-worktree provision: falls back to unfiltered fetch when --filter=blob:none fails" {
    # Wrap `git` via PATH so fetches that include --filter=blob:none fail, but
    # every other git invocation (including the retry without --filter) passes
    # through to the real git. This pins the fallback branch in pr-worktree.sh
    # that the happy-path test doesn't exercise.
    local fake_bin="$TEST_DIR/bin"
    local real_git
    real_git=$(command -v git)
    mkdir -p "$fake_bin"
    cat > "$fake_bin/git" << EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    if [[ "\$arg" == "--filter=blob:none" ]]; then
        echo "fake git: rejecting --filter=blob:none" >&2
        exit 128
    fi
done
exec "$real_git" "\$@"
EOF
    chmod +x "$fake_bin/git"

    PATH="$fake_bin:$PATH" run "$SCRIPT" provision myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Partial-clone fetch failed"* ]]

    # Worktree was created, so the unfiltered-fetch fallback succeeded.
    local canonical_root
    canonical_root=$(cd "$WORKTREE_ROOT" && pwd -P)
    [ -f "$canonical_root/myorg/myrepo/pr-42/file.txt" ]
}

@test "pr-worktree provision: recovers when reused worktree has dirty files" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>/dev/null" _ myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
    local wt_path
    wt_path=$(echo "$output" | jq -r '.worktree_path')

    # Simulate a crashed prior review: edit a tracked file in the worktree.
    echo "stale in-progress edit" > "$wt_path/file.txt"

    # Push a new commit so reuse must actually do a checkout.
    local seed3="$TEST_DIR/seed3"
    git clone --quiet "$BARE_ORIGIN" "$seed3"
    git -C "$seed3" config commit.gpgsign false
    git -C "$seed3" config user.email "test@example.com"
    git -C "$seed3" config user.name "Test User"
    git -C "$seed3" fetch --quiet origin "refs/pull/42/head:pr42"
    git -C "$seed3" checkout --quiet pr42
    echo "post-crash" >> "$seed3/file.txt"
    git -C "$seed3" commit --quiet -am "third pr commit"
    git -C "$seed3" push --quiet origin "HEAD:refs/pull/42/head"
    rm -rf "$seed3"

    run bash -c "'$SCRIPT' provision \"\$@\" 2>/dev/null" _ myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]

    # Worktree now reflects the PR ref, not the dirty edit.
    [ ! "$(cat "$wt_path/file.txt")" = "stale in-progress edit" ]
    grep -q "post-crash" "$wt_path/file.txt"
}

# =============================================================================
# teardown
# =============================================================================

@test "pr-worktree teardown: removes registered worktree" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>/dev/null" _ myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
    local wt_path
    wt_path=$(echo "$output" | jq -r '.worktree_path')
    [ -d "$wt_path" ]

    run "$SCRIPT" teardown myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
    [ ! -d "$wt_path" ]

    run git -C "$CLONE_DIR" worktree list --porcelain
    [[ "$output" != *"$wt_path"* ]]
}

@test "pr-worktree teardown: no-op when worktree already absent" {
    run "$SCRIPT" teardown myorg myrepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
}

# =============================================================================
# path layout
# =============================================================================

@test "pr-worktree provision: path layout follows worktree_path_for convention" {
    run bash -c "'$SCRIPT' provision \"\$@\" 2>/dev/null" _ MyOrg MyRepo 42 "$CLONE_DIR"
    [ "$status" -eq 0 ]
    local wt_path canonical_root
    wt_path=$(echo "$output" | jq -r '.worktree_path')
    canonical_root=$(cd "$WORKTREE_ROOT" && pwd -P)
    [ "$wt_path" = "$canonical_root/myorg/myrepo/pr-42" ]
}
