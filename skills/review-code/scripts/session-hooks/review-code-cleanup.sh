#!/usr/bin/env bash
# review-code-cleanup.sh - Per-session cleanup hook for /review-code sessions.
#
# Invoked by session-manager.sh when a review-code session is being torn down.
# Reads the session JSON, validates the stored worktree path, and asks
# pr-worktree.sh to remove the worktree if one was provisioned.
#
# Usage: review-code-cleanup.sh <session-file>
#
# Exits 0 in all cases; cleanup hooks must never fail the session teardown.

# Deliberately omit `-e`: a cleanup hook must never fail the session teardown.
# Each guard below exits 0 on its own so errors can't cascade.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../helpers/worktree-layout.sh
source "${SCRIPT_DIR}/../helpers/worktree-layout.sh"

session_file="${1:-}"
[[ -f "${session_file}" ]] || exit 0

# Read the five worktree-related fields in one jq pass. Capturing via command
# substitution + here-string (rather than `read < <(jq …)`) guarantees the read
# cannot fail: a jq error on malformed JSON leaves jq_out empty and read
# populates empty fields, instead of tripping `set -e` on an EOF return from
# read.
jq_out=""
jq_out=$(jq -r '[.git.org // "", .git.repo // "", .pr.number // "",
                .git.local_clone // "", .git.working_dir // ""] | @tsv' \
    "${session_file}" 2> /dev/null) || jq_out=""

IFS=$'\t' read -r wt_org wt_repo wt_pr wt_clone wt_path <<< "${jq_out}"

# Nothing to do if any field is missing (diff-only review, or this review
# didn't provision a worktree).
[[ -n "${wt_org}" && -n "${wt_repo}" && -n "${wt_pr}" \
    && -n "${wt_clone}" && -n "${wt_path}" ]] || exit 0

# Validate wt_path before trusting it: the stored path must be absolute and end
# with the expected <org>/<repo>/pr-<N> segments pr-worktree.sh wrote at
# provision. This stops a corrupted session file from redirecting teardown
# (which trusts REVIEW_CODE_WORKTREE_DIR) to an unrelated root.
expected_leaf=$(worktree_leaf_for "${wt_org}" "${wt_repo}" "${wt_pr}")
[[ "${wt_path}" == /* && "${wt_path}" == *"/${expected_leaf}" ]] || exit 0

wt_root="${wt_path%/${expected_leaf}}"
[[ -n "${wt_root}" ]] || exit 0

wt_script="${SCRIPT_DIR}/../pr-worktree.sh"
[[ -x "${wt_script}" ]] || exit 0

REVIEW_CODE_WORKTREE_DIR="${wt_root}" \
    "${wt_script}" teardown "${wt_org}" "${wt_repo}" "${wt_pr}" "${wt_clone}" \
    > /dev/null 2>&1 || true

exit 0
