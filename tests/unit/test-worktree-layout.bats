#!/usr/bin/env bats
# Tests for helpers/worktree-layout.sh - the single source of truth for the
# PR worktree filesystem layout.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HELPER="$PROJECT_ROOT/skills/review-code/scripts/helpers/worktree-layout.sh"
    export PROJECT_ROOT HELPER

    # shellcheck source=../../skills/review-code/scripts/helpers/worktree-layout.sh
    source "$HELPER"
}

@test "worktree_root: falls back to ~/.claude/skills/review-code/worktrees by default" {
    unset REVIEW_CODE_WORKTREE_DIR
    run worktree_root
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.claude/skills/review-code/worktrees" ]
}

@test "worktree_root: honors REVIEW_CODE_WORKTREE_DIR" {
    REVIEW_CODE_WORKTREE_DIR=/tmp/custom run worktree_root
    [ "$output" = "/tmp/custom" ]
}

@test "worktree_leaf_for: lowercases org and repo" {
    run worktree_leaf_for "Acme" "Widget" 42
    [ "$output" = "acme/widget/pr-42" ]
}

@test "worktree_leaf_for: preserves PR number verbatim" {
    run worktree_leaf_for "acme" "widget" 1234
    [ "$output" = "acme/widget/pr-1234" ]
}

@test "worktree_path_for: joins root and leaf" {
    REVIEW_CODE_WORKTREE_DIR=/tmp/wt run worktree_path_for "acme" "widget" 7
    [ "$output" = "/tmp/wt/acme/widget/pr-7" ]
}

@test "worktree_layout_depth: reports 3 (one for each path segment)" {
    run worktree_layout_depth
    [ "$output" = "3" ]
}
