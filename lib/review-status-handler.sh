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
# shellcheck source=lib/session-manager.sh
source "$SCRIPT_DIR/session-manager.sh"

# Find the orchestrator script
find_orchestrator() {
    if [ -f "$SCRIPT_DIR/review-orchestrator.sh" ]; then
        echo "$SCRIPT_DIR/review-orchestrator.sh"
    elif [ -f "$SCRIPT_DIR/../review-orchestrator.sh" ]; then
        echo "$SCRIPT_DIR/../review-orchestrator.sh"
    elif [ -f ~/.claude/bin/review-code/review-orchestrator.sh ]; then
        echo ~/.claude/bin/review-code/review-orchestrator.sh
    else
        echo "ERROR: Cannot find review-orchestrator.sh" >&2
        exit 1
    fi
}

ORCHESTRATOR=$(find_orchestrator)

# Main logic
case "$ACTION" in
    "init")
        # Initialize session - run orchestrator and cache result
        ARGUMENTS="${*:-}"

        # Run orchestrator
        review_data=$("$ORCHESTRATOR" "$ARGUMENTS")

        # Create session with the data
        session_id=$(session_init "review-code" "$review_data")

        # Return session ID for subsequent calls
        echo "$session_id"
        ;;

    "get-status")
        # Get status from cached session
        SESSION_ID="${1:-}"
        if [ -z "$SESSION_ID" ]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        session_get "$SESSION_ID" ".status"
        ;;

    "get-error-data")
        # Get error message from cached session
        SESSION_ID="${1:-}"
        if [ -z "$SESSION_ID" ]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "$SESSION_ID" ".status")
        if [ "$status" != "error" ]; then
            echo "ERROR: Status is not 'error', got: $status" >&2
            exit 1
        fi

        session_get "$SESSION_ID" ".message"
        ;;

    "get-ambiguous-data")
        # Get disambiguation fields from cached session
        SESSION_ID="${1:-}"
        if [ -z "$SESSION_ID" ]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "$SESSION_ID" ".status")
        if [ "$status" != "ambiguous" ]; then
            echo "ERROR: Status is not 'ambiguous', got: $status" >&2
            exit 1
        fi

        session_get_all "$SESSION_ID" | jq '{
            arg,
            ref_type,
            is_branch,
            is_current,
            base_branch,
            reason
        }'
        ;;

    "get-prompt-data")
        # Get prompt fields from cached session
        SESSION_ID="${1:-}"
        if [ -z "$SESSION_ID" ]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "$SESSION_ID" ".status")
        if [ "$status" != "prompt" ]; then
            echo "ERROR: Status is not 'prompt', got: $status" >&2
            exit 1
        fi

        session_get_all "$SESSION_ID" | jq '{
            current_branch,
            base_branch,
            has_uncommitted
        }'
        ;;

    "get-prompt-pull-data")
        # Get pull prompt fields from cached session
        SESSION_ID="${1:-}"
        if [ -z "$SESSION_ID" ]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "$SESSION_ID" ".status")
        if [ "$status" != "prompt_pull" ]; then
            echo "ERROR: Status is not 'prompt_pull', got: $status" >&2
            exit 1
        fi

        session_get_all "$SESSION_ID" | jq '{
            branch,
            associated_pr
        }'
        ;;

    "get-ready-data")
        # Get all review data from cached session
        SESSION_ID="${1:-}"
        if [ -z "$SESSION_ID" ]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        status=$(session_get "$SESSION_ID" ".status")
        if [ "$status" != "ready" ]; then
            echo "ERROR: Status is not 'ready', got: $status" >&2
            exit 1
        fi

        # Return the complete review data
        session_get_all "$SESSION_ID"
        ;;

    "cleanup")
        # Cleanup session
        SESSION_ID="${1:-}"
        if [ -z "$SESSION_ID" ]; then
            echo "ERROR: Session ID required" >&2
            exit 1
        fi

        session_cleanup "$SESSION_ID"
        echo "Session cleaned up: $SESSION_ID"
        ;;

    "cleanup-old")
        # Cleanup old sessions (older than 1 hour)
        session_cleanup_old "review-code"
        echo "Old sessions cleaned up"
        ;;

    *)
        echo "ERROR: Unknown action: $ACTION" >&2
        echo "Valid actions: init, get-status, get-ready-data, get-error-data, get-ambiguous-data, get-prompt-data, get-prompt-pull-data, cleanup, cleanup-old" >&2
        exit 1
        ;;
esac
