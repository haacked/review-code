#!/usr/bin/env bash
# pr-worktree.sh - Provision short-lived worktrees off a local clone for PR reviews.
#
# Usage:
#   pr-worktree.sh provision <org> <repo> <pr_number> <local_clone>
#     Fetches refs/pull/<N>/head into refs/review-code/pr/<N> inside the user's
#     clone, then creates (or reuses) a detached worktree at
#     ${REVIEW_CODE_WORKTREE_DIR:-$HOME/.claude/skills/review-code/worktrees}/<org>/<repo>/pr-<N>.
#
#     stdout: JSON {"worktree_path": "<abs>", "ref": "refs/review-code/pr/<N>"}
#     stderr: progress / diagnostics
#     exit 1 on fetch or worktree failure (caller falls back to diff-only)
#
#   pr-worktree.sh teardown <org> <repo> <pr_number> <local_clone>
#     Removes the worktree via `git worktree remove --force`. Keeps the ref
#     (trivially small; speeds up re-reviews of the same PR).
#     No error if the worktree is already gone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=helpers/repo-detection.sh
source "${SCRIPT_DIR}/helpers/repo-detection.sh"
# shellcheck source=helpers/worktree-layout.sh
source "${SCRIPT_DIR}/helpers/worktree-layout.sh"

export GIT_TERMINAL_PROMPT=0

# All progress output goes to stderr; stdout is reserved for the provision JSON.
log() {
    echo "$*" >&2
}

# Resolve symlinks in <path>. Needed because `git worktree list` returns
# canonical paths and direct string comparison breaks on macOS where
# /var -> /private/var. Falls back to the raw path when no ancestor resolves
# (e.g. during teardown of an already-gone worktree).
#
# stdout is intentionally the canonical path (consumed by
# `path=$(canonicalize ...)`); do not echo anything else inside this
# function — the file-level contract reserves stdout for the provision JSON.
canonicalize() {
    local p="$1"
    if [[ -d "${p}" ]]; then
        (cd "${p}" && pwd -P)
        return
    fi
    local parent="${p%/*}"
    local leaf="${p##*/}"
    [[ -z "${parent}" ]] && parent="/"
    if [[ -d "${parent}" ]]; then
        echo "$(cd "${parent}" && pwd -P)/${leaf}"
    else
        echo "${p}"
    fi
}

ref_for() {
    echo "refs/review-code/pr/$1"
}

validate_args() {
    local cmd="$1"
    local org="${2:-}"
    local repo="${3:-}"
    local pr_number="${4:-}"
    local local_clone="${5:-}"

    if [[ -z "${org}" || -z "${repo}" || -z "${pr_number}" || -z "${local_clone}" ]]; then
        error "Usage: pr-worktree.sh ${cmd} <org> <repo> <pr_number> <local_clone>"
        return 1
    fi
    if [[ ! "${pr_number}" =~ ^[0-9]+$ ]]; then
        error "Invalid PR number: ${pr_number}"
        return 1
    fi
    # org/repo become filesystem segments under WORKTREE_ROOT. Defense-in-depth
    # for any future caller that bypasses the orchestrator's upstream sanitization.
    if [[ ! "${org}" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "${org}" == "." || "${org}" == ".." ]]; then
        error "Invalid org: ${org}"
        return 1
    fi
    if [[ ! "${repo}" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "${repo}" == "." || "${repo}" == ".." ]]; then
        error "Invalid repo: ${repo}"
        return 1
    fi
    if ! is_git_repo "${local_clone}"; then
        error "Not a git repo: ${local_clone}"
        return 1
    fi
}

worktree_is_registered() {
    local clone="$1"
    local path="$2"
    git -C "${clone}" worktree list --porcelain 2> /dev/null \
        | grep -Fqx "worktree ${path}"
}

# Create a detached worktree at $path pointing at $ref. Caller must ensure the
# parent directory exists. Returns 1 on failure. git's stderr passes through
# so the "fatal: …" line surfaces to the caller; stdout is dropped so the
# "Preparing worktree" progress message doesn't leak into the provision JSON.
create_worktree() {
    local local_clone="$1"
    local path="$2"
    local ref="$3"
    git -C "${local_clone}" worktree add --detach "${path}" "${ref}" > /dev/null
}

provision() {
    validate_args provision "$@" || return 1
    local org="$1"
    local repo="$2"
    local pr_number="$3"
    local local_clone="$4"

    local ref
    ref=$(ref_for "${pr_number}")
    local path
    path=$(worktree_path_for "${org}" "${repo}" "${pr_number}")

    log "Fetching pull/${pr_number}/head into ${local_clone}…"
    # Try a partial-clone fetch first (fast on large repos), then fall back
    # to a regular fetch for older git or remotes that reject --filter.
    if ! git -C "${local_clone}" fetch --filter=blob:none origin \
        "+refs/pull/${pr_number}/head:${ref}" >&2; then
        log "Partial-clone fetch failed; retrying without --filter=blob:none…"
        if ! git -C "${local_clone}" fetch origin \
            "+refs/pull/${pr_number}/head:${ref}" >&2; then
            error "Fetch failed for ${org}/${repo}#${pr_number}"
            return 1
        fi
    fi

    mkdir -p "$(dirname "${path}")"
    path=$(canonicalize "${path}")

    if worktree_is_registered "${local_clone}" "${path}"; then
        log "Reusing worktree at ${path} (checking out ${ref})…"
        if ! git -C "${path}" checkout --detach "${ref}" > /dev/null 2>&1; then
            # Reused worktree has dirty state (a prior review crashed mid-edit,
            # or an agent wrote inside it). The detached checkout refuses to
            # overwrite. Discarding silently would lose work the user cared
            # about, so recreate the orchestrator-owned worktree instead.
            log "Checkout rejected (dirty worktree?); recreating…"
            git -C "${local_clone}" worktree remove --force "${path}" > /dev/null 2>&1 || true
            if ! create_worktree "${local_clone}" "${path}" "${ref}"; then
                error "Failed to recreate worktree at ${path}"
                return 1
            fi
        fi
    elif [[ -e "${path}" ]]; then
        local quoted_clone
        printf -v quoted_clone '%q' "${local_clone}"
        error "Path exists but is not a registered worktree: ${path}. Remove it manually or run \`git -C ${quoted_clone} worktree prune\` and retry."
        return 1
    else
        log "Creating worktree at ${path}…"
        if ! create_worktree "${local_clone}" "${path}" "${ref}"; then
            error "Worktree creation failed for ${org}/${repo}#${pr_number}"
            return 1
        fi
    fi

    jq -n --arg path "${path}" --arg ref "${ref}" \
        '{worktree_path: $path, ref: $ref}'
}

teardown() {
    validate_args teardown "$@" || return 1
    local org="$1"
    local repo="$2"
    local pr_number="$3"
    # local_clone is load-bearing for the crashed-session case: if the
    # worktree directory was deleted or rendered unusable between provision
    # and teardown, we can't derive the clone from the worktree's .git
    # pointer (which may be gone), but the clone still has a stale
    # registration that needs `git worktree remove --force` to drop.
    local local_clone="$4"

    local path
    path=$(worktree_path_for "${org}" "${repo}" "${pr_number}")
    path=$(canonicalize "${path}")

    if ! worktree_is_registered "${local_clone}" "${path}"; then
        return 0
    fi

    log "Removing worktree ${path}…"
    git -C "${local_clone}" worktree remove --force "${path}" > /dev/null 2>&1 || true
    # Best-effort cleanup of empty ancestor directories.
    local repo_dir="${path%/*}"
    local org_dir="${repo_dir%/*}"
    rmdir "${repo_dir}" 2> /dev/null || true
    rmdir "${org_dir}" 2> /dev/null || true
}

main() {
    local cmd="${1:-}"
    shift || true

    case "${cmd}" in
        provision)
            provision "$@"
            ;;
        teardown)
            teardown "$@"
            ;;
        *)
            error "Usage: pr-worktree.sh {provision|teardown} <org> <repo> <pr_number> <local_clone>"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
