#!/usr/bin/env bash
# shellcheck disable=SC2034  # OWNER/REPO_NAME/REPO/PR_NUMBER are this file's
# output contract; they are read by the scripts that source it, not here.
# pr-target.sh - Resolve a PR argument into OWNER/REPO_NAME/REPO/PR_NUMBER,
# plus the stderr logging the resolution reports through.
#
# Sourced by resolve-review-threads.sh and amend-pending-review.sh. Both take a
# PR the same three ways (inferred from the branch, a bare number, a full URL)
# and both keep stdout clean for JSON consumers, so the logging travels with
# the resolution rather than living apart from it.
#
# Sets: OWNER, REPO_NAME, REPO, PR_NUMBER.

# Guard against being sourced more than once per process.
[[ -n "${_PR_TARGET_SOURCED:-}" ]] && return
_PR_TARGET_SOURCED=1

_PR_TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/gh-wrapper.sh
source "${_PR_TARGET_DIR}/gh-wrapper.sh"

# ── Logging ──────────────────────────────────────────────────────────────────
# Log to stderr so stdout stays clean for JSON consumers.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ── PR target resolution ─────────────────────────────────────────────────────

# Parse a GitHub PR URL into OWNER, REPO_NAME, REPO, and PR_NUMBER.
parse_pr_url() {
    local url="$1"
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        OWNER="${BASH_REMATCH[1]}"
        REPO_NAME="${BASH_REMATCH[2]}"
        REPO="${OWNER}/${REPO_NAME}"
        PR_NUMBER="${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

get_current_repo() {
    gh repo view --json nameWithOwner -q '.nameWithOwner' 2> /dev/null || {
        log_error "Could not determine repository. Run from inside a repo or pass a full PR URL."
        exit 1
    }
}

# Resolve a PR argument (URL, number, or empty) into OWNER/REPO_NAME/REPO/PR_NUMBER.
resolve_pr_target() {
    local pr_arg="${1:-}"
    if [[ -z "$pr_arg" ]]; then
        local pr_url
        pr_url=$(gh pr view --json url -q '.url' 2> /dev/null) || {
            log_error "No PR found for the current branch. Specify a PR number or URL."
            exit 1
        }
        if ! parse_pr_url "$pr_url"; then
            log_error "Could not parse PR URL from current branch: ${pr_url}"
            exit 1
        fi
    elif parse_pr_url "$pr_arg"; then
        :
    elif [[ "$pr_arg" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$pr_arg"
        REPO=$(get_current_repo)
        OWNER="${REPO%%/*}"
        REPO_NAME="${REPO##*/}"
    else
        log_error "Invalid PR argument: ${pr_arg}"
        log_error "Expected a PR number or URL (https://github.com/owner/repo/pull/123)."
        exit 1
    fi
}
