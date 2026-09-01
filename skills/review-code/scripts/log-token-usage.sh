#!/usr/bin/env bash
set -euo pipefail

# log-token-usage.sh - Append one token-usage record to the central log.
#
# The caller passes the raw per-agent usage map and the review metadata; this
# script does the arithmetic. Having the model compute the sums by hand is how
# records ended up with agents_run: 0 and total_tokens: 0 while agents had in
# fact run, which made the log useless as a cost baseline.
#
# Usage:
#   log-token-usage.sh --review-file <path> --usage <json> [options]
#
# --usage is a JSON object mapping agent key to that agent's usage, accepting
# either shape:
#   {"code-reviewer-security": 88000, ...}
#   {"code-reviewer-security": {"total_tokens": 88000, "tool_uses": 12}, ...}
#
# Options: --org --repo --mode --identifier --diff-tokens --files-changed
#          --lines-added --lines-removed --exploration-depth --agents-run
#          --agents-skipped --review-mode --delta-from
#
# Prints the log path. The record always carries the token fields, even when the
# usage map is empty, so a missing baseline is visible rather than silent.

REVIEW_FILE=""
USAGE_JSON="{}"
ORG=""
REPO=""
MODE=""
IDENTIFIER=""
EXPLORATION_DEPTH=""
DIFF_TOKENS=0
FILES_CHANGED=0
LINES_ADDED=0
LINES_REMOVED=0
AGENTS_RUN=""
AGENTS_SKIPPED=0
REVIEW_MODE=""
DELTA_FROM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --review-file)
            REVIEW_FILE="${2:-}"
            shift 2
            ;;
        --usage)
            USAGE_JSON="${2:-}"
            shift 2
            ;;
        --org)
            ORG="${2:-}"
            shift 2
            ;;
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --mode)
            MODE="${2:-}"
            shift 2
            ;;
        --identifier)
            IDENTIFIER="${2:-}"
            shift 2
            ;;
        --diff-tokens)
            DIFF_TOKENS="${2:-0}"
            shift 2
            ;;
        --files-changed)
            FILES_CHANGED="${2:-0}"
            shift 2
            ;;
        --lines-added)
            LINES_ADDED="${2:-0}"
            shift 2
            ;;
        --lines-removed)
            LINES_REMOVED="${2:-0}"
            shift 2
            ;;
        --exploration-depth)
            EXPLORATION_DEPTH="${2:-}"
            shift 2
            ;;
        --agents-run)
            AGENTS_RUN="${2:-}"
            shift 2
            ;;
        --agents-skipped)
            AGENTS_SKIPPED="${2:-0}"
            shift 2
            ;;
        --review-mode)
            REVIEW_MODE="${2:-}"
            shift 2
            ;;
        --delta-from)
            DELTA_FROM="${2:-}"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${REVIEW_FILE}" ]]; then
    echo "ERROR: --review-file is required" >&2
    exit 1
fi

if ! echo "${USAGE_JSON}" | jq -e 'type == "object"' > /dev/null 2>&1; then
    echo "ERROR: --usage must be a JSON object" >&2
    exit 1
fi

# The log sits at the review root, three directories above <org>/<repo>/pr-N.md.
LOG_PATH="$(dirname "$(dirname "$(dirname "${REVIEW_FILE}")")")/token-usage.jsonl"
mkdir -p "$(dirname "${LOG_PATH}")"

# Normalize both accepted usage shapes to {agent: {total_tokens, tool_uses}}.
NORMALIZED=$(echo "${USAGE_JSON}" | jq -c '
    with_entries(
        .value |= (
            if type == "number" then {total_tokens: ., tool_uses: 0}
            elif type == "object" then {total_tokens: (.total_tokens // 0), tool_uses: (.tool_uses // 0)}
            else {total_tokens: 0, tool_uses: 0}
            end
        )
    )')

# Preserve step-specific counters that usage normalization would otherwise drop.
COUNTERS=$(echo "${USAGE_JSON}" | jq -c '
    with_entries(
        select(.value | type == "object")
        | .value |= del(.total_tokens, .tool_uses, .duration_ms)
        | select(.value | length > 0)
    )')

# agents_run defaults to the number of agents that actually reported usage,
# which is the honest count when the caller does not supply one. A step that
# consumed no tokens reported no usage, so it does not count.
if [[ -z "${AGENTS_RUN}" ]]; then
    AGENTS_RUN=$(echo "${NORMALIZED}" | jq '[.[] | select(.total_tokens > 0)] | length')
fi

RECORD=$(jq -nc \
    --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg org "${ORG}" \
    --arg repo "${REPO}" \
    --arg mode "${MODE}" \
    --arg identifier "${IDENTIFIER}" \
    --argjson diff_tokens "${DIFF_TOKENS:-0}" \
    --argjson files_changed "${FILES_CHANGED:-0}" \
    --argjson lines_added "${LINES_ADDED:-0}" \
    --argjson lines_removed "${LINES_REMOVED:-0}" \
    --arg exploration_depth "${EXPLORATION_DEPTH}" \
    --argjson agents_run "${AGENTS_RUN:-0}" \
    --argjson agents_skipped "${AGENTS_SKIPPED:-0}" \
    --arg review_mode "${REVIEW_MODE}" \
    --arg delta_from "${DELTA_FROM}" \
    --argjson usage "${NORMALIZED}" \
    --argjson counters "${COUNTERS}" \
    '{
        reviewed_at: $reviewed_at,
        org: $org,
        repo: $repo,
        mode: $mode,
        identifier: $identifier,
        diff_tokens: $diff_tokens,
        files_changed: $files_changed,
        lines_added: $lines_added,
        lines_removed: $lines_removed,
        exploration_depth: $exploration_depth,
        agents_run: $agents_run,
        agents_skipped: $agents_skipped,
        total_tokens: ([$usage[].total_tokens] | add // 0),
        total_tool_uses: ([$usage[].tool_uses] | add // 0),
        agents: ($usage | with_entries(.value |= .total_tokens))
    }
    + (if ($counters | length) > 0 then {counters: $counters} else {} end)
    + (if $review_mode != "" then {review_mode: $review_mode} else {} end)
    + (if $delta_from != "" then {delta_from: $delta_from} else {} end)')

printf '%s\n' "${RECORD}" >> "${LOG_PATH}"
echo "${LOG_PATH}"
