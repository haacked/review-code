#!/usr/bin/env bash
# repos-config.sh - Resolve local clone paths from repos.conf
#
# Config file format (flat, whitespace-separated):
#   # comments begin with hash
#   <org>/<repo>   <absolute-or-tilde-path>
#   posthog/posthog  ~/dev/posthog/posthog
#
# Location:
#   ~/.claude/skills/review-code/repos.conf
#   (overridable via $REVIEW_CODE_CONFIG_DIR for tests/advanced users)
#
# Usage (sourced):
#   source helpers/repos-config.sh
#   path=$(resolve_local_clone "posthog" "posthog")
#   # Empty string if not found or not a git repo.

_REPOS_CONFIG_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=repo-detection.sh
source "${_REPOS_CONFIG_HELPER_DIR}/repo-detection.sh"

# Find repos.conf. Echoes the file path on stdout and exits 0 when found,
# or exits 1 when not. The echoed path tracks the caller-supplied
# REVIEW_CODE_CONFIG_DIR verbatim, so a relative value yields a relative
# path; only the default fallback under ${HOME} is guaranteed absolute.
find_repos_config() {
    if [[ -n "${REVIEW_CODE_CONFIG_DIR:-}" ]]; then
        local candidate="${REVIEW_CODE_CONFIG_DIR%/}/repos.conf"
        if [[ -f "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
        # Treat a set override as an explicit commitment: if the file isn't
        # there, don't fall through to the default. Otherwise a typo'd
        # override (or a test scoping to a temp dir that doesn't have the
        # file) silently reads the host's real repos.conf.
        return 1
    fi

    local default="${HOME}/.claude/skills/review-code/repos.conf"
    if [[ -f "${default}" ]]; then
        echo "${default}"
        return 0
    fi

    return 1
}

# Look up org/repo in repos.conf. Echoes the resolved path if the entry
# exists and points at a git repo; empty otherwise.
resolve_local_clone() {
    local org="${1:-}"
    local repo="${2:-}"
    if [[ -z "${org}" || -z "${repo}" ]]; then
        return 0
    fi

    local config
    config=$(find_repos_config) || return 0
    # Require readability too: an unreadable config (permissions, transient FS)
    # would fail the awk below, and since we're sourced into a `set -e` parent,
    # that non-zero exit would abort the review instead of falling back to
    # diff-only. Treat unreadable the same as missing.
    [[ -n "${config}" && -f "${config}" && -r "${config}" ]] || return 0

    local key="${org}/${repo}"
    local raw_path=""
    raw_path=$(awk -v k="${key}" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            n = match(line, /[[:space:]]+/)
            if (n == 0) next
            if (tolower(substr(line, 1, n - 1)) == tolower(k)) {
                print substr(line, n + RLENGTH)
                exit
            }
        }
    ' "${config}" 2> /dev/null) || raw_path=""

    [[ -n "${raw_path}" ]] || return 0

    local expanded="${raw_path/#\~/${HOME}}"

    # Spec is <absolute-or-tilde-path>. A relative path would resolve against
    # the caller's cwd, which is surprising for a user-level machine map.
    if [[ "${expanded}" != /* ]]; then
        return 0
    fi

    if is_git_repo "${expanded}"; then
        echo "${expanded}"
    fi
}
