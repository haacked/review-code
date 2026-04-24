#!/usr/bin/env bash
# worktree-layout.sh - Single source of truth for the PR worktree filesystem layout.
#
# The layout is: ${REVIEW_CODE_WORKTREE_DIR}/<org>/<repo>/pr-<N>. Every consumer
# (pr-worktree.sh, session-hooks, bin/setup) should go through these helpers so
# changes to the shape live in one place.

# Root directory that holds all review worktrees.
worktree_root() {
    echo "${REVIEW_CODE_WORKTREE_DIR:-${HOME}/.claude/skills/review-code/worktrees}"
}

# Path leaf relative to worktree_root, e.g. "acme/widget/pr-7". Lowercases org
# and repo so the on-disk layout is stable regardless of caller casing.
worktree_leaf_for() {
    local org="$1"
    local repo="$2"
    local pr_number="$3"
    echo "${org,,}/${repo,,}/pr-${pr_number}"
}

# Absolute worktree path for a given org/repo/PR.
worktree_path_for() {
    local org="$1"
    local repo="$2"
    local pr_number="$3"
    echo "$(worktree_root)/$(worktree_leaf_for "${org}" "${repo}" "${pr_number}")"
}

# Depth beneath worktree_root where a worktree lives (for find -mindepth/-maxdepth).
worktree_layout_depth() {
    echo 3
}
