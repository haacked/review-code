#!/usr/bin/env bash
set -euo pipefail

# review-delta.sh - Decide whether a re-review can look at only what changed.
#
# A re-review of a PR pays full freight today: every agent reads the whole diff
# again, even when the author pushed a two-line fix. The last-reviewed SHA is
# already recorded as `review_commit:` in the review document's metadata header,
# so the delta since that SHA is computable.
#
# Safety is the whole game here. The bad outcome is a real bug shipping because
# the delta path skipped the file holding it, so every uncertain case falls back
# to a full review and says why. Nothing here fails quietly.
#
# Usage:
#   review-delta.sh --review-file <path> --head-sha <sha> --base <ref> [options]
#   review-delta.sh --review-commit <sha> --head-sha <sha> --base <ref> [options]
#
# Options:
#   --repo-dir <path>   Git repository to inspect (default: cwd)
#   --base <ref>        PR base branch. Required: the repository default is not
#                       the base of a stacked PR, and guessing it wrong reports
#                       a moved base and falls back to a full review.
#   --out <path>        Where to write the delta diff. Defaults to a fresh
#                       mktemp -d, which the caller owns: the diff outlives this
#                       script so the review can read it. Callers with a session
#                       pass their artifacts dir, which is swept with the session.
#   --max-fraction <n>  Fall back to full when the delta touches more than this
#                       fraction of the PR's files (default: 0.5)
#
# Output: a JSON object on stdout.
#   {"mode": "no-change"|"delta"|"full", "reason": "...", "diff_path": "...",
#    "delta_from": "<sha>", "changed_files": <n>, "pr_files": <n>}

HEAD_SHA=""
REVIEW_COMMIT=""
REVIEW_FILE=""
REPO_DIR="."
BASE_REF=""
OUT_PATH=""
MAX_FRACTION="0.5"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --head-sha)
            HEAD_SHA="${2:-}"
            shift 2
            ;;
        --review-commit)
            REVIEW_COMMIT="${2:-}"
            shift 2
            ;;
        --review-file)
            REVIEW_FILE="${2:-}"
            shift 2
            ;;
        --repo-dir)
            REPO_DIR="${2:-}"
            shift 2
            ;;
        --base)
            BASE_REF="${2:-}"
            shift 2
            ;;
        --out)
            OUT_PATH="${2:-}"
            shift 2
            ;;
        --max-fraction)
            MAX_FRACTION="${2:-0.5}"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

emit() {
    local mode="$1" reason="$2" diff_path="${3:-}" changed="${4:-0}" pr_files="${5:-0}"
    jq -nc \
        --arg mode "${mode}" \
        --arg reason "${reason}" \
        --arg diff_path "${diff_path}" \
        --arg delta_from "${REVIEW_COMMIT}" \
        --argjson changed_files "${changed}" \
        --argjson pr_files "${pr_files}" \
        '{mode: $mode, reason: $reason, delta_from: $delta_from,
          changed_files: $changed_files, pr_files: $pr_files}
         + (if $diff_path != "" then {diff_path: $diff_path} else {} end)'
}

if [[ -z "${HEAD_SHA}" ]]; then
    echo "ERROR: --head-sha is required" >&2
    exit 1
fi

# Deriving the base here would be worse than refusing: a wrong guess on a
# stacked PR looks like a moved base, which falls back to a full review with a
# reason that reads plausible. The caller knows the base; make it say so.
if [[ -z "${BASE_REF}" ]]; then
    echo "ERROR: --base is required" >&2
    exit 1
fi

# Recover the last-reviewed SHA from the review document when not given directly.
if [[ -z "${REVIEW_COMMIT}" && -n "${REVIEW_FILE}" ]]; then
    if [[ -f "${REVIEW_FILE}" ]]; then
        # Scoped to the metadata comment block, matching learn-from-pr.sh, so a
        # later mention of "review_commit:" in the review body cannot be read as
        # the header value.
        REVIEW_COMMIT=$(sed -n '/review-metadata/,/-->/{ /review_commit:/{ s/.*review_commit: *//; p; q; }; }' \
            "${REVIEW_FILE}" | tr -d '[:space:]')
    fi
fi

if [[ -z "${REVIEW_COMMIT}" ]]; then
    emit full "No review_commit recorded from a previous review; reviewing the full diff."
    exit 0
fi

if [[ ! -d "${REPO_DIR}" ]]; then
    emit full "Repository directory not found: ${REPO_DIR}; reviewing the full diff."
    exit 0
fi

git_in() { git -C "${REPO_DIR}" "$@"; }

if ! git_in rev-parse --git-dir > /dev/null 2>&1; then
    emit full "Not a git repository: ${REPO_DIR}; reviewing the full diff."
    exit 0
fi

# Both SHAs must actually resolve. A review_commit that was rewritten away by a
# force-push lands here.
if ! git_in cat-file -e "${REVIEW_COMMIT}^{commit}" 2> /dev/null; then
    emit full "Recorded review_commit ${REVIEW_COMMIT} is not in this repository (likely force-pushed or rebased away); reviewing the full diff."
    exit 0
fi

if ! git_in cat-file -e "${HEAD_SHA}^{commit}" 2> /dev/null; then
    emit full "Head ${HEAD_SHA} is not in this repository; reviewing the full diff."
    exit 0
fi

RESOLVED_REVIEW=$(git_in rev-parse "${REVIEW_COMMIT}^{commit}")
RESOLVED_HEAD=$(git_in rev-parse "${HEAD_SHA}^{commit}")

if [[ "${RESOLVED_REVIEW}" == "${RESOLVED_HEAD}" ]]; then
    emit no-change "Head is unchanged since the last review (${REVIEW_COMMIT}); there is no change to review."
    exit 0
fi

# A rebase or force-push breaks ancestry, and a diff across rewritten history is
# not the set of changes the author actually made since the review.
if ! git_in merge-base --is-ancestor "${RESOLVED_REVIEW}" "${RESOLVED_HEAD}" 2> /dev/null; then
    emit full "Recorded review_commit ${REVIEW_COMMIT} is not an ancestor of head (force-push or rebase); reviewing the full diff."
    exit 0
fi

# A PR stacked on someone else's branch, or based on a release branch the user
# never checked out, has the base only as a remote-tracking ref. Falling back to
# a full review in that case would cost the saving on exactly those PRs.
if ! git_in rev-parse --verify --quiet "${BASE_REF}" > /dev/null 2>&1; then
    if git_in rev-parse --verify --quiet "origin/${BASE_REF}" > /dev/null 2>&1; then
        BASE_REF="origin/${BASE_REF}"
    else
        emit full "PR base '${BASE_REF}' could not be resolved locally; reviewing the full diff."
        exit 0
    fi
fi

# If the base moved under the PR, the earlier review was taken against different
# surrounding code and its untouched-file findings can no longer be trusted.
BASE_AT_REVIEW=$(git_in merge-base "${BASE_REF}" "${RESOLVED_REVIEW}" 2> /dev/null || echo "")
BASE_AT_HEAD=$(git_in merge-base "${BASE_REF}" "${RESOLVED_HEAD}" 2> /dev/null || echo "")
if [[ -z "${BASE_AT_REVIEW}" || -z "${BASE_AT_HEAD}" ]]; then
    emit full "Could not compute the merge-base against '${BASE_REF}'; reviewing the full diff."
    exit 0
fi
if [[ "${BASE_AT_REVIEW}" != "${BASE_AT_HEAD}" ]]; then
    emit full "The PR base moved since the last review (${BASE_AT_REVIEW:0:8} → ${BASE_AT_HEAD:0:8}); reviewing the full diff."
    exit 0
fi

DELTA_FILES=$(git_in diff --name-only "${RESOLVED_REVIEW}..${RESOLVED_HEAD}" | grep -c . || true)
PR_FILES=$(git_in diff --name-only "${BASE_AT_HEAD}..${RESOLVED_HEAD}" | grep -c . || true)

if [[ "${DELTA_FILES}" -eq 0 ]]; then
    emit no-change "No files changed between ${REVIEW_COMMIT} and head; there is no change to review."
    exit 0
fi

# Past roughly half the PR, a delta review saves little and risks carrying
# forward findings whose surrounding code has shifted.
if [[ "${PR_FILES}" -gt 0 ]]; then
    if awk -v d="${DELTA_FILES}" -v p="${PR_FILES}" -v f="${MAX_FRACTION}" 'BEGIN { exit !(d > p * f) }'; then
        emit full "The delta touches ${DELTA_FILES} of the PR's ${PR_FILES} files, more than the ${MAX_FRACTION} threshold; reviewing the full diff." "" "${DELTA_FILES}" "${PR_FILES}"
        exit 0
    fi
fi

if [[ -z "${OUT_PATH}" ]]; then
    OUT_PATH="$(mktemp -d)/delta.patch"
fi
mkdir -p "$(dirname "${OUT_PATH}")"
git_in diff "${RESOLVED_REVIEW}..${RESOLVED_HEAD}" > "${OUT_PATH}"

if [[ ! -s "${OUT_PATH}" ]]; then
    emit full "The delta diff came back empty despite ${DELTA_FILES} changed files; reviewing the full diff." "" "${DELTA_FILES}" "${PR_FILES}"
    exit 0
fi

emit delta "Reviewing the ${DELTA_FILES} file(s) changed since ${REVIEW_COMMIT}, out of ${PR_FILES} in the PR." "${OUT_PATH}" "${DELTA_FILES}" "${PR_FILES}"
