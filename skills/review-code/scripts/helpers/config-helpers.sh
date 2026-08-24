#!/bin/bash
# Configuration helpers
# Provides path resolution for the review-code skill
#
# Canonical skill directory (Codex-compatible):
#   ~/.agents/skills/review-code/
#     context/     - Language, framework, and org context files
#     .reviews/    - Review output files (org/repo/pr.md)
#     .learnings/  - Learning index
#     scripts/     - Helper scripts
#
# Claude Code reads the same tree through a
# ~/.claude/skills/review-code -> ~/.agents/skills/review-code symlink,
# so both harnesses share learnings, reviews, and updates.
#
# Runtime state (reviews, learnings, sessions, worktrees) lives in
# dot-prefixed directories so skill scanners that ignore dot-directories
# don't count it against the skill's file budget.

# Get the skill installation directory
# Uses HOME at call time to support testing with alternate HOME values
get_skill_dir() {
    echo "${HOME}/.agents/skills/review-code"
}

# Get the legacy Claude-only skill directory. Used as a fallback when a
# pre-port install still exists and the canonical directory has not been
# created yet. bin/setup migrates this to the canonical layout.
get_skill_dir_legacy() {
    echo "${HOME}/.claude/skills/review-code"
}

# Get the skill directory, falling back to the legacy location when the
# canonical one is absent. Prefer this over get_skill_dir for read paths so
# an existing install keeps working until bin/setup migrates it.
resolve_skill_dir() {
    local canonical
    canonical="$(get_skill_dir)"
    if [[ -d "${canonical}" ]]; then
        echo "${canonical}"
        return 0
    fi
    local legacy
    legacy="$(get_skill_dir_legacy)"
    if [[ -d "${legacy}" ]]; then
        echo "${legacy}"
        return 0
    fi
    # Neither exists yet; return canonical so install paths converge there.
    echo "${canonical}"
}

# Get the review root path (where review files are stored)
# Usage: review_root=$(get_review_root)
#
# Reviews are stored at: {review_root}/{org}/{repo}/{identifier}.md
#
# Returns:
#   The review root path on stdout
get_review_root() {
    echo "$(resolve_skill_dir)/.reviews"
}

# Get the context path (where context files are stored)
# Usage: context_path=$(get_context_path)
#
# Context files are stored at:
#   {context_path}/languages/{lang}.md
#   {context_path}/frameworks/{framework}.md
#   {context_path}/orgs/{org}/org.md
#   {context_path}/orgs/{org}/repos/{repo}.md
#
# Returns:
#   The context path on stdout
get_context_path() {
    echo "$(resolve_skill_dir)/context"
}

# Get the learnings directory path
# Usage: learnings_dir=$(get_learnings_dir)
#
# Returns:
#   The learnings directory path on stdout
get_learnings_dir() {
    echo "$(resolve_skill_dir)/.learnings"
}
