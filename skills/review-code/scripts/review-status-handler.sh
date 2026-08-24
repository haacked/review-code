#!/usr/bin/env bash
set -euo pipefail

# Review Status Handler with Session Caching
# Calls the orchestrator ONCE and caches the result in a session file.
# Subsequent calls read from the cached session, avoiding expensive re-runs.
# This dramatically reduces token usage (60% savings) and improves performance.

# Usage: review-status-handler.sh <action> [session-id] [args...]
# Actions:
#   init <args>                - Initialize session, run orchestrator, return session ID
#   get-status <session-id>    - Get status from cached session
#   get-ready-data <session-id> - Get all data for "ready" status from cache
#   get-review-fields <session-id> - Get only the small orchestrator-facing fields (no diff/context/PR body)
#   get-error-data <session-id> - Get error message from cache
#   get-ambiguous-data <session-id> - Get disambiguation fields from cache
#   get-prompt-data <session-id> - Get prompt fields from cache
#   get-prompt-pull-data <session-id> - Get pull prompt fields from cache
#   cleanup <session-id>       - Cleanup session files

ACTION="${1:-init}"
shift || true

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source session manager
# shellcheck source=session-manager.sh
source "${SCRIPT_DIR}/session-manager.sh"

# Find the orchestrator script
find_orchestrator() {
    if [[ -f "${SCRIPT_DIR}/review-orchestrator.sh" ]]; then
        echo "${SCRIPT_DIR}/review-orchestrator.sh"
    elif [[ -f "${SCRIPT_DIR}/../review-orchestrator.sh" ]]; then
        echo "${SCRIPT_DIR}/../review-orchestrator.sh"
    elif [[ -f "$(resolve_skill_dir)/scripts/review-orchestrator.sh" ]]; then
        echo "$(resolve_skill_dir)/scripts/review-orchestrator.sh"
    else
        echo "ERROR: Cannot find review-orchestrator.sh" >&2
        exit 1
    fi
}

ORCHESTRATOR=$(find_orchestrator)

# Main logic
case "${ACTION}" in
    "init")
        # Sweep sessions (and worktrees) from a crashed/abandoned prior review.
        # 24h threshold avoids reaping one still paused on a prompt elsewhere.
        session_cleanup_old "review-code" 1440 2> /dev/null || true

        # Large payloads (the diff, the agent briefing) live in this directory as
        # files rather than inside the session JSON, so the orchestrating model
        # never pulls them into its context just to hand them to a subagent.
        REVIEW_CODE_ARTIFACTS_DIR=$(session_artifacts_dir_new "review-code")
        export REVIEW_CODE_ARTIFACTS_DIR

        # Initialize session - run orchestrator and cache result
        # Pass arguments separately to preserve word splitting
        review_data=$("${ORCHESTRATOR}" "$@")

        # Create session with the data
        session_id=$(session_init "review-code" "${review_data}")

        # Return session ID for subsequent calls
        echo "${session_id}"
        ;;

    "get-status")
        # Get status from cached session
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        session_get "${SESSION_ID}" ".status"
        ;;

    "get-error-data")
        # Get error message from cached session
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "${SESSION_ID}" ".status")
        if [[ "${status}" != "error" ]]; then
            echo "ERROR: Status is not 'error', got: ${status}" >&2
            exit 1
        fi

        session_get "${SESSION_ID}" ".message"
        ;;

    "get-ambiguous-data")
        # Get disambiguation fields from cached session
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "${SESSION_ID}" ".status")
        if [[ "${status}" != "ambiguous" ]]; then
            echo "ERROR: Status is not 'ambiguous', got: ${status}" >&2
            exit 1
        fi

        session_get_all "${SESSION_ID}" | jq '{
            arg,
            ref_type,
            is_branch,
            is_current,
            base_branch,
            base_source,
            reason
        }
        + (if .base_lookup_degraded then {base_lookup_degraded} else {} end)'
        ;;

    "get-prompt-data")
        # Get prompt fields from cached session
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "${SESSION_ID}" ".status")
        if [[ "${status}" != "prompt" ]]; then
            echo "ERROR: Status is not 'prompt', got: ${status}" >&2
            exit 1
        fi

        session_get_all "${SESSION_ID}" | jq '{
            current_branch,
            base_branch,
            base_source,
            has_uncommitted
        }
        + (if .base_lookup_degraded then {base_lookup_degraded} else {} end)'
        ;;

    "get-prompt-pull-data")
        # Get pull prompt fields from cached session
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "${SESSION_ID}" ".status")
        if [[ "${status}" != "prompt_pull" ]]; then
            echo "ERROR: Status is not 'prompt_pull', got: ${status}" >&2
            exit 1
        fi

        session_get_all "${SESSION_ID}" | jq '{
            branch,
            associated_pr
        }'
        ;;

    "get-ready-data")
        # Get all review data from cached session
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "${SESSION_ID}" ".status")
        if [[ "${status}" != "ready" ]]; then
            echo "ERROR: Status is not 'ready', got: ${status}" >&2
            exit 1
        fi

        # Return the complete review data
        session_get_all "${SESSION_ID}"
        ;;

    "get-review-fields")
        # Narrow accessor for the review handler. Returns only the small fields the
        # orchestrating model actually reasons about. The diff, review_context, PR
        # body and PR comments are deliberately excluded: they are large, they are
        # already written to files for the subagents, and pulling them into the
        # orchestrator's context costs their size on every subsequent turn.
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        session_get_all "${SESSION_ID}" | jq -c '{
            mode,
            status,
            diff_tokens,
            languages,
            file_info,
            file_metadata,
            display_summary,
            summary,
            git: (.git // null),
            diff_path: (.diff_path // null),
            artifacts_dir: (.artifacts_dir // null),
            file_ref: (.file_ref // null),
            chunk_metadata: (.chunk_metadata // null),
            chunks: (if .chunks then [.chunks[] | {id, label, files, size_kb, diff_path}] else null end),
            commit_messages_present: (has("commit_messages")),
            adversary: (.adversary // null)
        }
        + ({force, draft, self, overwrite, append, full, fix} | with_entries(select(.value)))
        + (if .debug_session_dir then {debug_session_dir} else {} end)
        + (if .pr then {pr: {number: .pr.number, title: .pr.title, author: .pr.author, url: .pr.url, base: .pr.base, head: .pr.head, head_sha: .pr.head_sha, linked_issues: [.pr.linked_issues[]? | {number, title}]}, reviewer_username, is_own_pr} else {} end)
        + (if .branch then {branch} else {} end)
        + (if .base_branch then {base_branch} else {} end)
        + (if .base_source then {base_source} else {} end)
        + (if .commit then {commit} else {} end)
        + (if .range then {range} else {} end)
        + (if .area then {area} else {} end)'
        ;;

    "get-find-data")
        # Get find mode data from cached session
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "${SESSION_ID}" ".status")
        if [[ "${status}" != "find" ]]; then
            echo "ERROR: Status is not 'find', got: ${status}" >&2
            exit 1
        fi

        # Return the find data
        session_get_all "${SESSION_ID}"
        ;;

    "cleanup")
        # Cleanup session
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        session_cleanup "${SESSION_ID}"
        echo "Session cleaned up: ${SESSION_ID}"
        ;;

    "cleanup-old")
        # Cleanup old sessions (older than 1 hour)
        session_cleanup_old "review-code"
        echo "Old sessions cleaned up"
        ;;

    "get-session-file")
        # Get the path to the session file for direct jq access
        # This avoids control character corruption when piping through bash variables
        SESSION_ID="${1:-}"
        if [[ -z "${SESSION_ID}" ]]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        session_file "${SESSION_ID}"
        ;;

    *)
        echo "ERROR: Unknown action: ${ACTION}" >&2
        echo "Valid actions: init, get-status, get-ready-data, get-review-fields, get-find-data, get-error-data, get-ambiguous-data, get-prompt-data, get-prompt-pull-data, get-session-file, cleanup, cleanup-old" >&2
        exit 1
        ;;
esac
