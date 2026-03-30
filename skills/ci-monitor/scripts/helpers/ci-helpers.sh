#!/usr/bin/env bash
# ci-helpers.sh - Shared constants and utilities for ci-monitor skill
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/helpers/ci-helpers.sh"

# ── Constants ────────────────────────────────────────────────────────────────

CI_POLL_INTERVAL=30   # seconds between polls
CI_TIMEOUT_MINUTES=30 # default overall timeout
CI_MAX_FIX_RETRIES=3  # max fix-push-monitor cycles
CI_LOG_TAIL_LINES=200 # lines of log to keep per failed job

# ── Source shared helpers from review-code ───────────────────────────────────

_CI_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REVIEW_HELPERS="${HOME}/.claude/skills/review-code/scripts/helpers"

if [[ -f "${_REVIEW_HELPERS}/git-helpers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_REVIEW_HELPERS}/git-helpers.sh"
elif [[ -f "${_CI_HELPER_DIR}/../../../review-code/scripts/helpers/git-helpers.sh" ]]; then
    # Fallback for development (running from repo)
    # shellcheck source=/dev/null
    source "${_CI_HELPER_DIR}/../../../review-code/scripts/helpers/git-helpers.sh"
fi

if [[ -f "${_REVIEW_HELPERS}/gh-wrapper.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_REVIEW_HELPERS}/gh-wrapper.sh"
elif [[ -f "${_CI_HELPER_DIR}/../../../review-code/scripts/helpers/gh-wrapper.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_CI_HELPER_DIR}/../../../review-code/scripts/helpers/gh-wrapper.sh"
fi

# ── Utility Functions ────────────────────────────────────────────────────────

# Get the list of files changed in a PR
# Usage: ci_get_pr_changed_files <pr_number> [<org/repo>]
ci_get_pr_changed_files() {
    local pr_number="$1"
    local repo="${2:-}"
    local repo_flag=()
    if [[ -n "${repo}" ]]; then
        repo_flag=(--repo "${repo}")
    fi
    gh pr diff "${pr_number}" "${repo_flag[@]}" --name-only 2> /dev/null || echo ""
}

# JSON output helper
ci_json_error() {
    local message="$1"
    jq -n --arg msg "${message}" '{"error": $msg}'
}
