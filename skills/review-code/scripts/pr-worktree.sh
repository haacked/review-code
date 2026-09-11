#!/usr/bin/env bash
# pr-worktree.sh - Provision short-lived worktrees off a local clone for PR reviews.
#
# Usage:
#   pr-worktree.sh provision <org> <repo> <pr_number> <local_clone>
#     Fetches refs/pull/<N>/head into refs/review-code/pr/<N> inside the user's
#     clone, then creates (or reuses) a detached worktree at
#     ${REVIEW_CODE_WORKTREE_DIR:-$HOME/.agents/skills/review-code/.worktrees}/<org>/<repo>/pr-<N>.
#
#     stdout: JSON {"worktree_path": "<abs>", "ref": "refs/review-code/pr/<N>"}
#     stderr: progress / diagnostics
#     exit 1 on fetch or worktree failure (caller falls back to diff-only)
#
#     Set REVIEW_CODE_PR_SHA to check out one commit of the PR rather than its
#     head; the returned "ref" is then that sha. It must be reachable from the
#     fetched ref, and provision fails rather than silently using the head when
#     it is not. Used by frozen-diff evals, where reading the head would show
#     agents the corrections the author pushed after the diff was captured.
#
#   pr-worktree.sh teardown <org> <repo> <pr_number> <local_clone>
#     Removes the worktree no matter what state it is in, including one an
#     external tool has locked and one with uncommitted edits. Keeps the ref
#     (trivially small; speeds up re-reviews of the same PR). No error if the
#     worktree is already gone.
#
#     These worktrees are orchestrator-owned scratch, not a place to work: only
#     provision creates them, always at <org>/<repo>/pr-<N> under the skill's
#     worktree root, and always as a detached checkout of a PR head. See
#     teardown for why removal is unconditional.
#
# Both commands serialize on a per-org/repo mkdir-based lock before touching
# the local clone, since concurrent `git fetch`/`git worktree add|remove`
# against the same clone is not safe (see worktree_lock_for). Lock wait tops
# out at REVIEW_CODE_LOCK_TIMEOUT seconds (default 30). On timeout, provision's
# caller falls back to diff-only; teardown's caller swallows the failure and
# leaves the worktree in place for a later run to remove.

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

LOCK_DIR=""

cleanup_lock() {
    if [[ -n "${LOCK_DIR}" ]]; then
        rmdir "${LOCK_DIR}" 2> /dev/null || true
    fi
}
trap cleanup_lock EXIT INT TERM

# Serializes provision/teardown per org/repo (see worktree_lock_for). mkdir is
# the lock primitive: atomic create, no extra dependency, and portable (macOS
# has no `flock`). The EXIT/INT/TERM trap clears it on normal exit and on
# Ctrl-C/terminate, but a SIGKILL or OOM-kill leaves the directory behind;
# there is no stale-lock recovery yet, so a killed holder wedges every future
# provision/teardown for that org/repo until someone manually rmdirs it.
acquire_lock() {
    local lockfile="$1"
    local waited=0
    mkdir -p "$(dirname "${lockfile}")"
    while ! mkdir "${lockfile}" 2> /dev/null; do
        sleep 1
        waited=$((waited + 1))
        if ((waited >= ${REVIEW_CODE_LOCK_TIMEOUT:-30})); then
            error "Timed out waiting for worktree lock: ${lockfile}"
            return 1
        fi
    done
    LOCK_DIR="${lockfile}"
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

# Drop a worktree registration and its directory. Best effort: git's output is
# discarded and failures are swallowed, so callers can't branch on the result.
# Both --force flags are load-bearing: the first discards uncommitted state, and
# the second overrides a lock. Some environments (e.g. Supacode's worktree
# manager) lock any git worktree they discover on disk, including ones we
# provision for ourselves, and a single --force refuses to touch a locked one.
force_remove_worktree() {
    local local_clone="$1"
    local path="$2"
    git -C "${local_clone}" worktree remove --force --force "${path}" > /dev/null 2>&1 || true
}

provision() {
    validate_args provision "$@" || return 1
    local org="$1"
    local repo="$2"
    local pr_number="$3"
    local local_clone="$4"

    acquire_lock "$(worktree_lock_for "${org}" "${repo}")" || return 1

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

    # REVIEW_CODE_PR_SHA pins the checkout to one commit of the PR instead of
    # its current head. Freezing only the diff is not enough for a benchmark:
    # agents are told to verify each line by reading the file, so they read
    # whatever the author has since pushed. The commit must be reachable from
    # the ref just fetched, which is what makes a plain checkout of it work.
    local checkout_ref="${ref}"
    if [[ -n "${REVIEW_CODE_PR_SHA:-}" ]]; then
        if ! git -C "${local_clone}" merge-base --is-ancestor \
            "${REVIEW_CODE_PR_SHA}" "${ref}" 2> /dev/null; then
            error "REVIEW_CODE_PR_SHA ${REVIEW_CODE_PR_SHA} is not reachable from ${ref}"
            return 1
        fi
        checkout_ref="${REVIEW_CODE_PR_SHA}"
        log "Pinning checkout to ${checkout_ref} instead of the head of ${ref}"
    fi

    mkdir -p "$(dirname "${path}")"
    path=$(canonicalize "${path}")

    if worktree_is_registered "${local_clone}" "${path}"; then
        log "Reusing worktree at ${path} (checking out ${checkout_ref})…"
        if ! git -C "${path}" checkout --detach "${checkout_ref}" > /dev/null 2>&1; then
            # Reused worktree has dirty state (a prior review crashed mid-edit,
            # or an agent wrote inside it). The detached checkout refuses to
            # overwrite. Discarding silently would lose work the user cared
            # about, so recreate the orchestrator-owned worktree instead.
            log "Checkout rejected (dirty worktree?); recreating…"
            force_remove_worktree "${local_clone}" "${path}"
            if ! create_worktree "${local_clone}" "${path}" "${checkout_ref}"; then
                error "Failed to recreate worktree at ${path}"
                return 1
            fi
        fi
    elif [[ -e "${path}" ]]; then
        error "Path exists but is not a registered worktree: ${path}. Delete it and retry."
        return 1
    else
        log "Creating worktree at ${path}…"
        if ! create_worktree "${local_clone}" "${path}" "${checkout_ref}"; then
            error "Worktree creation failed for ${org}/${repo}#${pr_number}"
            return 1
        fi
    fi

    jq -n --arg path "${path}" --arg ref "${checkout_ref}" \
        '{worktree_path: $path, ref: $ref}'
}

teardown() {
    validate_args teardown "$@" || return 1
    local org="$1"
    local repo="$2"
    local pr_number="$3"
    # local_clone can't be derived from the worktree's .git pointer, which may
    # be gone by teardown time, so the caller passes it.
    local local_clone="$4"

    acquire_lock "$(worktree_lock_for "${org}" "${repo}")" || return 1

    local path
    path=$(worktree_path_for "${org}" "${repo}" "${pr_number}")
    path=$(canonicalize "${path}")

    if ! worktree_is_registered "${local_clone}" "${path}"; then
        return 0
    fi

    # Removal is unconditional, dirty checkout or not. Provision owns this
    # directory and its reuse path already force-removes and recreates the
    # worktree as soon as the checkout is too dirty to check out over, so
    # declining here would only postpone the same discard until the next review
    # of the same PR, and leave an orphan on disk until then.
    log "Removing worktree ${path}…"
    force_remove_worktree "${local_clone}" "${path}"
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
