#!/usr/bin/env bash
# debug-artifact-writer.sh - Bridge script for Claude-side debug artifacts
#
# Reads JSON from stdin and writes debug artifacts to the session directory.
# Used by review.md to capture Claude-side stages (context explorer, per-chunk
# analysis, agent dispatch, synthesis) that run outside bash scripts.
#
# Usage:
#   echo '{"action": "save", "debug_dir": "...", "stage": "...", "filename": "...", "content": "..."}' | debug-artifact-writer.sh
#
# Actions:
#   save  - Write content to {debug_dir}/{stage}/{filename}
#   copy  - Copy a review session artifact to {debug_dir}/{stage}/{filename}
#   time  - Append ndjson timing event to {debug_dir}/timing.ndjson
#   stats - Write stats JSON to {debug_dir}/{stage}/stats.json
#
# All errors are non-fatal: the script exits 0 even on failure to avoid
# blocking the review.

set -euo pipefail

main() {
    local input
    input=$(cat) || {
        echo "Warning: failed to read stdin" >&2
        exit 0
    }

    # Parse common fields in a single jq call
    local action debug_dir stage
    read -r action debug_dir stage < <(
        echo "${input}" | jq -r '[.action // "", .debug_dir // "", .stage // ""] | @tsv'
    ) || {
        echo "Warning: invalid JSON" >&2
        exit 0
    }

    # Validate debug_dir: must be non-empty and under ~/.cache/review-code/debug/
    if [[ -z "${debug_dir}" ]]; then
        echo "Warning: empty debug_dir" >&2
        exit 0
    fi

    local expected_prefix="${HOME}/.cache/review-code/debug/"
    # Also allow REVIEW_CODE_DEBUG_PATH if set
    local alt_prefix="${REVIEW_CODE_DEBUG_PATH:-}"

    if [[ "${debug_dir}/" != "${expected_prefix}"* ]]; then
        if [[ -n "${alt_prefix}" ]] && [[ "${debug_dir}/" == "${alt_prefix}/"* ]]; then
            : # Valid alternative path
        else
            echo "Warning: debug_dir '${debug_dir}' is not under expected prefix" >&2
            exit 0
        fi
    fi

    # Validate debug_dir exists
    if [[ ! -d "${debug_dir}" ]]; then
        echo "Warning: debug_dir does not exist: ${debug_dir}" >&2
        exit 0
    fi

    # Validate stage for path traversal (used by all actions that take a stage)
    if [[ -n "${stage}" ]] && [[ "${stage}" == *".."* ]]; then
        echo "Warning: invalid stage (path traversal)" >&2
        exit 0
    fi

    case "${action}" in
        save | copy)
            local filename
            filename=$(echo "${input}" | jq -r '.filename // ""') || exit 0

            if [[ -z "${stage}" ]] || [[ -z "${filename}" ]]; then
                echo "Warning: ${action} requires stage and filename" >&2
                exit 0
            fi

            # Prevent path traversal in filename
            if [[ "${filename}" == *".."* ]] || [[ "${filename}" == *"/"* ]]; then
                echo "Warning: invalid filename (path traversal)" >&2
                exit 0
            fi

            local stage_dir="${debug_dir}/${stage}"
            mkdir -p "${stage_dir}"

            if [[ "${action}" == "save" ]]; then
                # Content needs separate extraction (can contain tabs/newlines)
                local content
                content=$(echo "${input}" | jq -r '.content // ""') || exit 0
                printf '%s' "${content}" > "${stage_dir}/${filename}"
            else
                local source_path
                source_path=$(echo "${input}" | jq -r '.source_path // ""') || exit 0
                if [[ ! -f "${source_path}" ]]; then
                    echo "Warning: copy source does not exist: ${source_path}" >&2
                    exit 0
                fi

                local canonical_source
                canonical_source=$(realpath "${source_path}") || exit 0
                local source_allowed="false"
                local session_root canonical_root
                for session_root in "${HOME}/.agents/skills/review-code/.sessions" "${CLAUDE_SESSION_DIR:-}"; do
                    [[ -n "${session_root}" && -d "${session_root}" ]] || continue
                    canonical_root=$(cd "${session_root}" && pwd -P)
                    if [[ "${canonical_source}" == "${canonical_root}/"* ]]; then
                        source_allowed="true"
                        break
                    fi
                done
                if [[ "${source_allowed}" != "true" ]]; then
                    echo "Warning: copy source is outside the review session directory" >&2
                    exit 0
                fi

                cp "${canonical_source}" "${stage_dir}/${filename}"
            fi
            ;;

        time)
            local event
            event=$(echo "${input}" | jq -r '.event // ""') || exit 0

            if [[ -z "${stage}" ]] || [[ -z "${event}" ]]; then
                echo "Warning: time requires stage and event" >&2
                exit 0
            fi

            local timestamp
            timestamp=$(date +%s.%N)

            jq -nc \
                --arg stage "${stage}" \
                --arg event "${event}" \
                --arg timestamp "${timestamp}" \
                '{stage: $stage, event: $event, timestamp: ($timestamp | tonumber)}' \
                >> "${debug_dir}/timing.ndjson" || true
            ;;

        stats)
            if [[ -z "${stage}" ]]; then
                echo "Warning: stats requires stage" >&2
                exit 0
            fi

            local stats_data
            stats_data=$(echo "${input}" | jq -c '.data // {}') || exit 0

            local stage_dir="${debug_dir}/${stage}"
            mkdir -p "${stage_dir}"
            echo "${stats_data}" | jq '.' > "${stage_dir}/stats.json" || true
            ;;

        "")
            echo "Warning: no action specified" >&2
            exit 0
            ;;

        *)
            echo "Warning: unknown action '${action}'" >&2
            exit 0
            ;;
    esac
}

main "$@"
