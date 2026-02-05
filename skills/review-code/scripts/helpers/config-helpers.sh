#!/bin/bash
# Configuration helpers
# Provides path resolution for the review-code skill
#
# All paths are now relative to the skill directory:
#   ~/.claude/skills/review-code/
#     context/     - Language, framework, and org context files
#     reviews/     - Review output files (org/repo/pr.md)
#     learnings/   - Learning index
#     scripts/     - Helper scripts

# Get the skill installation directory
# Uses HOME at call time to support testing with alternate HOME values
get_skill_dir() {
    echo "${HOME}/.claude/skills/review-code"
}

# Get the review root path (where review files are stored)
# Usage: review_root=$(get_review_root)
#
# Reviews are stored at: {review_root}/{org}/{repo}/{identifier}.md
#
# Returns:
#   The review root path on stdout
get_review_root() {
    echo "$(get_skill_dir)/reviews"
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
    echo "$(get_skill_dir)/context"
}

# Get the learnings directory path
# Usage: learnings_dir=$(get_learnings_dir)
#
# Returns:
#   The learnings directory path on stdout
get_learnings_dir() {
    echo "$(get_skill_dir)/learnings"
}
