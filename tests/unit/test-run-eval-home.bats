#!/usr/bin/env bats
# prepare_eval_home in evals/scripts/run-eval.sh installs the checkout into a
# scratch HOME. These tests run it against a fake real HOME, so they check what
# it installs, what it links, and what it leaves alone. Every test only reads
# the result, so setup_file builds it once.

setup_file() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    REAL_HOME="$BATS_FILE_TMPDIR/real-home"
    DESKTOP_HOME="$REAL_HOME/Library/Application Support/@posthog/posthog-code/claude"
    mkdir -p "$DESKTOP_HOME" "$REAL_HOME/.agents/skills/review-code" "$REAL_HOME/dev"
    echo "acme/widget  ~/dev/widget" > "$REAL_HOME/.agents/skills/review-code/repos.conf"
    printf '[user]\n\tname = Eval\n\temail = eval@example.com\n' > "$REAL_HOME/.gitconfig"
    export HOME="$REAL_HOME"
    unset CLAUDE_CONFIG_DIR CODEX_HOME REVIEW_CODE_REVIEW_DIR REVIEW_CODE_WORKTREE_DIR

    SOURCE_REPO="$BATS_FILE_TMPDIR/source-repo"
    git init --quiet -b feature "$SOURCE_REPO"
    git -C "$SOURCE_REPO" commit --quiet --allow-empty -m "base" --no-gpg-sign
    git -C "$SOURCE_REPO" remote add origin git@github.com:acme/widget.git
    export EVAL_TARGET_REPO="$SOURCE_REPO"

    WORK_DIR="$BATS_FILE_TMPDIR/work"

    source "$PROJECT_ROOT/evals/scripts/run-eval.sh"
    prepare_eval_home "$WORK_DIR"
    export REAL_HOME DESKTOP_HOME SOURCE_REPO WORK_DIR
    export EVAL_HOME EVAL_SKILL_DIR EVAL_SESSION_DIR TARGET_REPO
}

@test "run-eval: installs this checkout's skill and agents into the scratch HOME" {
    [ "$EVAL_HOME" = "$WORK_DIR/home" ]
    [ -f "$EVAL_HOME/.agents/skills/review-code/SKILL.md" ]
    cmp -s "$PROJECT_ROOT/agents/code-reviewer-correctness.md" "$EVAL_HOME/.claude/agents/code-reviewer-correctness.md"
}

@test "run-eval: leaves the real HOME's installs untouched" {
    [ -z "$(ls -A "$DESKTOP_HOME")" ]
    [ ! -e "$REAL_HOME/.claude" ]
    [ ! -e "$REAL_HOME/.codex" ]
    [ "$(ls -A "$REAL_HOME/.agents/skills/review-code")" = "repos.conf" ]
}

@test "run-eval: links the rest of the real HOME and copies repos.conf" {
    [ "$(readlink "$EVAL_HOME/Library")" = "$REAL_HOME/Library" ]
    [ "$(readlink "$EVAL_HOME/.gitconfig")" = "$REAL_HOME/.gitconfig" ]
    [ "$(readlink "$EVAL_HOME/dev")" = "$REAL_HOME/dev" ]
    [ ! -L "$EVAL_HOME/.agents" ]
    cmp -s "$REAL_HOME/.agents/skills/review-code/repos.conf" "$EVAL_HOME/.agents/skills/review-code/repos.conf"
}

@test "run-eval: both session directories dispatch the scratch agents" {
    [ "$(cd "$EVAL_SESSION_DIR/.claude/agents" && pwd -P)" = "$(cd "$EVAL_HOME/.claude/agents" && pwd -P)" ]
    [ "$(cd "$TARGET_REPO/.claude/agents" && pwd -P)" = "$(cd "$EVAL_HOME/.claude/agents" && pwd -P)" ]
}

@test "run-eval: the crafted clone diffs against the source HEAD and keeps its origin" {
    [ "$TARGET_REPO" = "$WORK_DIR/target" ]
    local head
    head=$(git -C "$SOURCE_REPO" rev-parse HEAD)
    [ "$(git -C "$TARGET_REPO" rev-parse HEAD)" = "$head" ]
    [ "$(git -C "$TARGET_REPO" rev-parse origin/main)" = "$head" ]
    [ "$(git -C "$TARGET_REPO" branch --show-current)" = "main" ]
    [ "$(git -C "$TARGET_REPO" symbolic-ref refs/remotes/origin/HEAD)" = "refs/remotes/origin/main" ]
    [ "$(git -C "$TARGET_REPO" remote get-url origin)" = "git@github.com:acme/widget.git" ]
    [ -z "$(git -C "$TARGET_REPO" status --porcelain)" ]
}

@test "run-eval: the review prompt reads the scratch install's skill" {
    local home="$EVAL_HOME" skill_dir="$EVAL_SKILL_DIR"
    [ "$skill_dir" = "$home/.agents/skills/review-code" ]
    # Sourcing resets the variables prepare_eval_home set.
    source "$PROJECT_ROOT/evals/scripts/run-eval.sh"
    EVAL_SKILL_DIR="$skill_dir"
    run skill_prompt "my-branch --force"
    [[ "$output" == "Read $home/.agents/skills/review-code/SKILL.md and follow"* ]]
}

@test "run-eval: refuses a target repository that tracks its own .claude/agents" {
    local source="$BATS_TEST_TMPDIR/tracked-agents"
    git init --quiet -b main "$source"
    mkdir -p "$source/.claude/agents"
    echo "tracked" > "$source/.claude/agents/code-reviewer-correctness.md"
    git -C "$source" add -A
    git -C "$source" commit --quiet -m "agents" --no-gpg-sign
    git -C "$source" remote add origin git@github.com:acme/tracked.git

    EVAL_TARGET_REPO="$source" run bash -c 'source "$PROJECT_ROOT/evals/scripts/run-eval.sh" && prepare_eval_home "$1"' _ "$BATS_TEST_TMPDIR/work"

    [ "$status" -ne 0 ]
    [[ "$output" == *".claude/agents is a directory"* ]]
    [ ! -L "$BATS_TEST_TMPDIR/work/target/.claude/agents/agents" ]
}
