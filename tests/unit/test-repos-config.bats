#!/usr/bin/env bats
# Tests for helpers/repos-config.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HELPER="$PROJECT_ROOT/skills/review-code/scripts/helpers/repos-config.sh"
    export PROJECT_ROOT HELPER

    TEST_DIR=$(mktemp -d)
    # Isolate from the real home so the default repos.conf location
    # (~/.claude/skills/review-code/repos.conf) doesn't bleed into tests.
    export HOME="$TEST_DIR/fakehome"
    mkdir -p "$HOME"

    CLONE_DIR="$TEST_DIR/myclone"
    git init --quiet "$CLONE_DIR"
    git -C "$CLONE_DIR" config commit.gpgsign false
    git -C "$CLONE_DIR" config user.email "test@example.com"
    git -C "$CLONE_DIR" config user.name "Test User"

    BARE_DIR="$TEST_DIR/mybare.git"
    git init --bare --quiet "$BARE_DIR"

    CONF_DIR="$TEST_DIR/conf"
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/repos.conf" << EOF
# comment line
posthog/posthog  $CLONE_DIR
someorg/bareone  $BARE_DIR

MixedCase/MixedRepo   $CLONE_DIR
missing/path     /does/not/exist
EOF

    export TEST_DIR CLONE_DIR BARE_DIR CONF_DIR
    unset REVIEW_CODE_CONFIG_DIR || true
}

teardown() {
    rm -rf "$TEST_DIR"
}

run_resolve() {
    # shellcheck source=/dev/null
    source "$HELPER"
    resolve_local_clone "$@"
}

run_find() {
    # shellcheck source=/dev/null
    source "$HELPER"
    find_repos_config
}

# =============================================================================
# resolve_local_clone
# =============================================================================

@test "resolve_local_clone: returns path for configured non-bare repo" {
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve posthog posthog)
    [ "$result" = "$CLONE_DIR" ]
}

@test "resolve_local_clone: returns path for configured bare repo" {
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve someorg bareone)
    [ "$result" = "$BARE_DIR" ]
}

@test "resolve_local_clone: returns empty for missing key" {
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve nosuch repo)
    [ -z "$result" ]
}

@test "resolve_local_clone: ignores comments and blank lines" {
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve posthog posthog)
    [ "$result" = "$CLONE_DIR" ]
}

@test "resolve_local_clone: case-insensitive match on config entries" {
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve mixedcase mixedrepo)
    [ "$result" = "$CLONE_DIR" ]
}

@test "resolve_local_clone: returns empty when configured path is not a git repo" {
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve missing path)
    [ -z "$result" ]
}

@test "resolve_local_clone: expands leading tilde" {
    local suffix="rc-test-$$-$RANDOM"
    local homed="$HOME/$suffix"
    git init --quiet "$homed"

    cat > "$CONF_DIR/repos.conf" << EOF
tilde/repo  ~/$suffix
EOF
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve tilde repo)
    rm -rf "$homed"
    [ "$result" = "$homed" ]
}

@test "resolve_local_clone: empty org or repo arg returns empty" {
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve "" "")
    [ -z "$result" ]
}

# =============================================================================
# find_repos_config
# =============================================================================

@test "find_repos_config: REVIEW_CODE_CONFIG_DIR wins" {
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    cd "$TEST_DIR"
    result=$(run_find)
    [ "$result" = "$CONF_DIR/repos.conf" ]
}

@test "find_repos_config: falls back to ~/.claude/skills/review-code/repos.conf" {
    local default_dir="$HOME/.claude/skills/review-code"
    mkdir -p "$default_dir"
    cp "$CONF_DIR/repos.conf" "$default_dir/repos.conf"
    result=$(run_find)
    [ "$result" = "$default_dir/repos.conf" ]
}

@test "find_repos_config: REVIEW_CODE_CONFIG_DIR wins over the default location" {
    local default_dir="$HOME/.claude/skills/review-code"
    mkdir -p "$default_dir"
    echo "# default file" > "$default_dir/repos.conf"
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_find)
    [ "$result" = "$CONF_DIR/repos.conf" ]
}

@test "find_repos_config: returns empty when nothing found" {
    # No REVIEW_CODE_CONFIG_DIR, no default file under the fake HOME.
    result=$(run_find || true)
    [ -z "$result" ]
}

@test "find_repos_config: REVIEW_CODE_CONFIG_DIR without a repos.conf does not fall back to the default" {
    # If the override points at a directory with no repos.conf, treat the
    # override as an explicit commitment and return nothing. Otherwise a
    # typo'd override would silently read the host's real config.
    local default_dir="$HOME/.claude/skills/review-code"
    mkdir -p "$default_dir"
    echo "# default file" > "$default_dir/repos.conf"

    local empty_dir="$TEST_DIR/empty-override"
    mkdir -p "$empty_dir"
    export REVIEW_CODE_CONFIG_DIR="$empty_dir"

    result=$(run_find || true)
    [ -z "$result" ]
}

# =============================================================================
# Bare-repo detection
# =============================================================================

@test "resolve_local_clone: rejects dir with objects/ but no HEAD" {
    local fake="$TEST_DIR/fake-bare"
    mkdir -p "$fake/objects"
    cat > "$CONF_DIR/repos.conf" << EOF
fake/bare  $fake
EOF
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve fake bare)
    [ -z "$result" ]
}

@test "resolve_local_clone: accepts dir with both objects/ and HEAD" {
    local fake="$TEST_DIR/fake-bare-head"
    mkdir -p "$fake/objects"
    touch "$fake/HEAD"
    cat > "$CONF_DIR/repos.conf" << EOF
fake/bare  $fake
EOF
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve fake bare)
    [ "$result" = "$fake" ]
}

@test "resolve_local_clone: accepts worktree-style repo where .git is a file" {
    local worktree="$TEST_DIR/worktree-repo"
    local gitdir="$TEST_DIR/worktree-gitdir"
    mkdir -p "$worktree" "$gitdir/objects"
    printf 'ref: refs/heads/main\n' > "$gitdir/HEAD"
    printf 'gitdir: %s\n' "$gitdir" > "$worktree/.git"
    cat > "$CONF_DIR/repos.conf" << EOF
fake/worktree  $worktree
EOF
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve fake worktree)
    [ "$result" = "$worktree" ]
}

@test "resolve_local_clone: accepts worktree whose gitdir uses commondir instead of objects" {
    local worktree="$TEST_DIR/linked-worktree"
    local gitdir="$TEST_DIR/linked-gitdir"
    mkdir -p "$worktree" "$gitdir"
    printf 'ref: refs/heads/main\n' > "$gitdir/HEAD"
    printf '%s\n' "$TEST_DIR/shared.git" > "$gitdir/commondir"
    printf 'gitdir: %s\n' "$gitdir" > "$worktree/.git"
    cat > "$CONF_DIR/repos.conf" << EOF
fake/linked  $worktree
EOF
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve fake linked)
    [ "$result" = "$worktree" ]
}

@test "resolve_local_clone: rejects .git file with stale gitdir pointer" {
    local worktree="$TEST_DIR/stale-worktree"
    mkdir -p "$worktree"
    printf 'gitdir: %s/does-not-exist\n' "$TEST_DIR" > "$worktree/.git"
    cat > "$CONF_DIR/repos.conf" << EOF
fake/stale  $worktree
EOF
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve fake stale)
    [ -z "$result" ]
}

@test "resolve_local_clone: rejects relative paths" {
    cat > "$CONF_DIR/repos.conf" << EOF
rel/path  some/relative/repo
EOF
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    result=$(run_resolve rel path)
    [ -z "$result" ]
}

@test "resolve_local_clone: ignores malformed single-token line" {
    cat > "$CONF_DIR/repos.conf" << EOF
onlyname
posthog/posthog  $CLONE_DIR
EOF
    export REVIEW_CODE_CONFIG_DIR="$CONF_DIR"
    # Good entry after the malformed line still resolves.
    result=$(run_resolve posthog posthog)
    [ "$result" = "$CLONE_DIR" ]
}

@test "find_repos_config: exits 1 when nothing found" {
    unset REVIEW_CODE_CONFIG_DIR
    (
        # shellcheck disable=SC1090
        source "$HELPER"
        if find_repos_config > /dev/null; then
            echo "expected non-zero exit"
            exit 2
        fi
    )
}
