#!/usr/bin/env bash
# repo-detection.sh - Zero-dependency git-repo detection helper.
#
# Usage (sourced):
#   source "$(dirname "${BASH_SOURCE[0]}")/repo-detection.sh"
#   is_git_repo "${path}" && echo "yes"

# Check if a directory looks like a valid git metadata dir: HEAD plus either
# objects/ (normal/bare repo) or commondir (linked worktree).
# Args: $1 = git metadata directory path
# Returns: exit 0 if valid, 1 otherwise.
_is_valid_git_dir() {
    local git_dir="$1"
    [[ -d "${git_dir}" && -f "${git_dir}/HEAD" ]] || return 1
    [[ -d "${git_dir}/objects" || -f "${git_dir}/commondir" ]]
}

# Check if a directory looks like a git repository (bare or non-bare).
# Accepts `.git` as either a directory (normal clone) or a file (worktree
# or submodule, where `.git` contains `gitdir: <path>`). For the file form,
# the referenced gitdir must itself resolve to a valid metadata dir so a
# stale `gitdir:` pointer isn't mistaken for a real clone.
# Args: $1 = path
# Returns: exit 0 if it is, 1 otherwise. No output.
is_git_repo() {
    local path="$1"
    if [[ -d "${path}/.git" ]]; then
        _is_valid_git_dir "${path}/.git"
        return
    fi
    if [[ -f "${path}/.git" ]]; then
        local first_line="" gitdir_path=""
        read -r first_line < "${path}/.git" 2> /dev/null || return 1
        [[ "${first_line}" == gitdir:* ]] || return 1
        gitdir_path="${first_line#gitdir:}"
        # Trim leading/trailing whitespace.
        gitdir_path="${gitdir_path#"${gitdir_path%%[![:space:]]*}"}"
        gitdir_path="${gitdir_path%"${gitdir_path##*[![:space:]]}"}"
        [[ -n "${gitdir_path}" ]] || return 1
        # Relative gitdir paths are resolved against the directory containing
        # the `.git` file (git's own convention for submodule pointers).
        [[ "${gitdir_path}" != /* ]] && gitdir_path="${path}/${gitdir_path}"
        _is_valid_git_dir "${gitdir_path}"
        return
    fi
    _is_valid_git_dir "${path}"
}
