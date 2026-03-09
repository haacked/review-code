#!/usr/bin/env bash
# detect-comment-drift.sh - Detect and remap drifted PR review comments
#
# When a PR receives new commits between review generation and draft posting,
# line numbers drift. This script detects that drift by comparing the review's
# commit SHA against the PR's current HEAD, then re-maps comments to their
# correct positions using content-based matching.
#
# Usage:
#   echo '<json_input>' | detect-comment-drift.sh
#
# Input JSON:
#   {
#     "owner": "org",
#     "repo": "repo",
#     "pr_number": 123,
#     "review_commit": "abc123...",
#     "comments": [
#       {"path": "src/foo.py", "line": 42, "side": "RIGHT", "body": "...", "line_content": "    some_code()"}
#     ],
#     "original_diff": "<optional: the diff from review time>"
#   }
#
# Output JSON:
#   {
#     "drift_detected": false|true,
#     "review_commit": "abc123...",
#     "current_commit": "def456...",
#     "comments": [...remapped comments...],
#     "unmapped_comments": [...comments that couldn't be placed...],
#     "drift_summary": "3 comments remapped, 1 unmapped"
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=lib/helpers/json-helpers.sh
source "${SCRIPT_DIR}/helpers/json-helpers.sh"
# shellcheck source=lib/helpers/gh-wrapper.sh
source "${SCRIPT_DIR}/helpers/gh-wrapper.sh"

# Fetch the current HEAD commit SHA for a PR
# Args: $1 = owner, $2 = repo, $3 = pr_number
# Output: commit SHA string
get_current_pr_head() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"

    gh api "repos/${owner}/${repo}/pulls/${pr_number}" --jq '.head.sha'
}

# Fetch the current diff for a PR
# Args: $1 = owner, $2 = repo, $3 = pr_number
# Output: unified diff content
fetch_current_diff() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"

    gh pr diff "${pr_number}" --repo "${owner}/${repo}"
}

# Extract the line content at a given file path and line number from a diff.
# Parses the diff to find the file's hunks and locates the content at the
# specified new-file line number.
# Args: $1 = diff, $2 = file path, $3 = line number
# Output: the line content (with +/- prefix stripped), or empty if not found
extract_line_content_from_diff() {
    local diff="$1"
    local target_path="$2"
    local target_line="$3"

    echo "${diff}" | awk -v target_path="${target_path}" -v target_line="${target_line}" '
    BEGIN {
        in_file = 0
        new_line = 0
        in_hunk = 0
    }

    /^diff --git/ {
        # Extract b/ path
        idx = match($0, / b\//)
        if (idx > 0) {
            current_file = substr($0, idx + 3)
            in_file = (current_file == target_path)
        } else {
            in_file = 0
        }
        in_hunk = 0
        next
    }

    /^@@/ && in_file {
        # Parse +N from hunk header for new line start
        idx = index($0, "+")
        if (idx > 0) {
            rest = substr($0, idx + 1)
            gsub(/[^0-9].*/, "", rest)
            new_line = rest + 0
        }
        in_hunk = 1
        next
    }

    !in_file || !in_hunk { next }

    # Skip file-level diff headers
    /^---/ || /^\+\+\+/ { next }

    # Removed line (-) only advances old line counter
    /^-/ {
        next
    }

    # Added line (+)
    /^\+/ {
        if (new_line == target_line) {
            print substr($0, 2)
            exit
        }
        new_line++
        next
    }

    # Context line (space prefix or blank line within a hunk).
    # Git may strip the leading space from blank context lines, so an
    # empty line inside a hunk is treated as context.
    {
        if (new_line == target_line) {
            if (substr($0, 1, 1) == " ") {
                print substr($0, 2)
            } else {
                print $0
            }
            exit
        }
        new_line++
    }
    '
}

# Search a diff for a line with matching content in a specific file.
# Returns the new line number where the content appears, or nothing if not found.
# When multiple matches exist, returns the one closest to the original line.
# Args: $1 = diff, $2 = file path, $3 = line content to find, $4 = original line number
# Output: the new line number, or empty if not found
find_line_in_diff() {
    local diff="$1"
    local target_path="$2"
    local content="$3"
    local original_line="$4"

    # Normalize the search content by trimming whitespace
    local trimmed_content
    trimmed_content=$(echo "${content}" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    if [[ -z "${trimmed_content}" ]]; then
        return
    fi

    # Find all matching line numbers in the file within the diff
    local matches
    matches=$(echo "${diff}" | awk -v target_path="${target_path}" -v trimmed_content="${trimmed_content}" '
    BEGIN {
        in_file = 0
        new_line = 0
        in_hunk = 0
    }

    /^diff --git/ {
        idx = match($0, / b\//)
        if (idx > 0) {
            current_file = substr($0, idx + 3)
            in_file = (current_file == target_path)
        } else {
            in_file = 0
        }
        in_hunk = 0
        next
    }

    /^@@/ && in_file {
        idx = index($0, "+")
        if (idx > 0) {
            rest = substr($0, idx + 1)
            gsub(/[^0-9].*/, "", rest)
            new_line = rest + 0
        }
        in_hunk = 1
        next
    }

    !in_file || !in_hunk { next }

    # Skip file-level diff headers
    /^---/ || /^\+\+\+/ { next }

    # Removed line
    /^-/ {
        next
    }

    # Added line
    /^\+/ {
        line_text = substr($0, 2)
        gsub(/^[[:space:]]+/, "", line_text)
        gsub(/[[:space:]]+$/, "", line_text)
        if (line_text == trimmed_content) {
            print new_line
        }
        new_line++
        next
    }

    # Context line (space prefix or blank line within a hunk)
    {
        if (substr($0, 1, 1) == " ") {
            line_text = substr($0, 2)
        } else {
            line_text = $0
        }
        gsub(/^[[:space:]]+/, "", line_text)
        gsub(/[[:space:]]+$/, "", line_text)
        if (line_text == trimmed_content) {
            print new_line
        }
        new_line++
    }
    ')

    if [[ -z "${matches}" ]]; then
        return
    fi

    # If multiple matches, pick the closest to the original line
    local best_match=""
    local best_distance=""
    while IFS= read -r match_line; do
        local distance
        distance=$((match_line - original_line))
        if [[ ${distance} -lt 0 ]]; then
            distance=$((-distance))
        fi
        if [[ -z "${best_distance}" ]] || [[ ${distance} -lt ${best_distance} ]]; then
            best_distance=${distance}
            best_match=${match_line}
        fi
    done <<< "${matches}"

    echo "${best_match}"
}

# Check whether a file appears in the diff
# Args: $1 = diff, $2 = file path
# Output: "true" or "false"
file_in_diff() {
    local diff="$1"
    local target_path="$2"

    if [[ "${diff}" == *"diff --git a/${target_path} b/${target_path}"* ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# Remap a single comment against the current diff.
# Uses content-based matching to find where the comment's target line moved.
# Args: $1 = comment JSON, $2 = original_diff, $3 = current_diff
# Output: JSON object with remapped comment (return 0) or unmapped entry (return 1)
remap_comment() {
    local comment="$1"
    local original_diff="$2"
    local current_diff="$3"

    local path line line_content
    read -r path line line_content < <(
        echo "${comment}" | jq -r '[.path, (.line | tostring), (.line_content // "")] | @tsv'
    )

    # If line_content wasn't provided, try to extract it from the original diff
    if [[ -z "${line_content}" ]] && [[ -n "${original_diff}" ]]; then
        line_content=$(extract_line_content_from_diff "${original_diff}" "${path}" "${line}")
    fi

    # If we still have no line content, we cannot remap this comment
    if [[ -z "${line_content}" ]]; then
        echo "${comment}" | jq '{path, line, side: (.side // "RIGHT"), body, reason: "no line content available for matching"}'
        return 1
    fi

    # Check if the file still exists in the current diff
    if [[ "$(file_in_diff "${current_diff}" "${path}")" == "false" ]]; then
        echo "${comment}" | jq '{path, line, side: (.side // "RIGHT"), body, reason: "file removed from diff"}'
        return 1
    fi

    # Search for the content in the current diff
    local new_line
    new_line=$(find_line_in_diff "${current_diff}" "${path}" "${line_content}" "${line}")

    if [[ -z "${new_line}" ]]; then
        echo "${comment}" | jq '{path, line, side: (.side // "RIGHT"), body, reason: "line content not found in current diff"}'
        return 1
    fi

    # Return the remapped comment
    if [[ "${new_line}" -eq "${line}" ]]; then
        # Line didn't move, no remapping needed
        echo "${comment}" | jq --argjson new_line "${new_line}" \
            '. + {remapped: false}'
    else
        echo "${comment}" | jq --argjson new_line "${new_line}" --argjson orig_line "${line}" \
            '. + {line: $new_line, original_line: $orig_line, remapped: true}'
    fi
    return 0
}

main() {
    # Read input JSON from stdin
    local input
    input=$(cat)

    # Validate input
    validate_json "${input}" || exit 1

    # Extract fields
    local owner repo pr_number review_commit comments original_diff
    read -r owner repo pr_number review_commit < <(
        echo "${input}" | jq -r '[.owner, .repo, (.pr_number | tostring), (.review_commit // "")] | @tsv'
    )
    comments=$(echo "${input}" | jq -c '.comments // []')
    original_diff=$(echo "${input}" | jq -r '.original_diff // ""')

    # If no review_commit provided, skip drift detection entirely
    if [[ -z "${review_commit}" ]] || [[ "${review_commit}" == "null" ]]; then
        jq -n \
            --argjson comments "${comments}" \
            '{
                drift_detected: false,
                review_commit: null,
                current_commit: null,
                comments: $comments,
                unmapped_comments: [],
                drift_summary: "skipped (no review commit)"
            }'
        return 0
    fi

    # Validate required fields
    require_field "${owner}" "owner" || exit 1
    require_field "${repo}" "repo" || exit 1
    require_field "${pr_number}" "pr_number" || exit 1

    # Fetch the current PR HEAD
    local current_commit
    if ! current_commit=$(get_current_pr_head "${owner}" "${repo}" "${pr_number}" 2>&1); then
        warning "Failed to fetch current PR HEAD: ${current_commit}"
        # Non-fatal: return original comments unchanged
        jq -n \
            --arg review_commit "${review_commit}" \
            --argjson comments "${comments}" \
            '{
                drift_detected: false,
                review_commit: $review_commit,
                current_commit: null,
                comments: $comments,
                unmapped_comments: [],
                drift_summary: "skipped (failed to fetch current HEAD)"
            }'
        return 0
    fi

    # If commits match, no drift
    if [[ "${review_commit}" == "${current_commit}" ]]; then
        jq -n \
            --arg review_commit "${review_commit}" \
            --arg current_commit "${current_commit}" \
            --argjson comments "${comments}" \
            '{
                drift_detected: false,
                review_commit: $review_commit,
                current_commit: $current_commit,
                comments: $comments,
                unmapped_comments: [],
                drift_summary: "no drift (same commit)"
            }'
        return 0
    fi

    # Drift detected: fetch the current diff
    local current_diff
    if ! current_diff=$(fetch_current_diff "${owner}" "${repo}" "${pr_number}" 2>&1); then
        warning "Failed to fetch current diff: ${current_diff}"
        # Non-fatal: return original comments unchanged
        jq -n \
            --arg review_commit "${review_commit}" \
            --arg current_commit "${current_commit}" \
            --argjson comments "${comments}" \
            '{
                drift_detected: true,
                review_commit: $review_commit,
                current_commit: $current_commit,
                comments: $comments,
                unmapped_comments: [],
                drift_summary: "drift detected but remap failed (could not fetch current diff)"
            }'
        return 0
    fi

    # Remap each comment
    local remapped_results=""
    local unmapped_results=""
    local remapped_count=0
    local unmapped_count=0
    local comment_count
    comment_count=$(echo "${comments}" | jq 'length')

    if [[ "${comment_count}" -eq 0 ]]; then
        jq -n \
            --arg review_commit "${review_commit}" \
            --arg current_commit "${current_commit}" \
            '{
                drift_detected: true,
                review_commit: $review_commit,
                current_commit: $current_commit,
                comments: [],
                unmapped_comments: [],
                drift_summary: "drift detected, no comments to remap"
            }'
        return 0
    fi

    while IFS= read -r comment; do
        # remap_comment writes JSON to stdout in both success and failure paths
        local result
        if result=$(remap_comment "${comment}" "${original_diff}" "${current_diff}"); then
            remapped_results+="${result}"$'\n'
            # Count actual remaps (where the line moved)
            local was_remapped
            was_remapped=$(echo "${result}" | jq -r '.remapped // false')
            if [[ "${was_remapped}" == "true" ]]; then
                remapped_count=$((remapped_count + 1))
            fi
        else
            unmapped_results+="${result}"$'\n'
            unmapped_count=$((unmapped_count + 1))
        fi
    done < <(echo "${comments}" | jq -c '.[]')

    # Assemble arrays from collected NDJSON in one jq call each
    local remapped_comments unmapped_comments
    if [[ -n "${remapped_results}" ]]; then
        remapped_comments=$(echo "${remapped_results}" | jq -s '.')
    else
        remapped_comments="[]"
    fi
    if [[ -n "${unmapped_results}" ]]; then
        unmapped_comments=$(echo "${unmapped_results}" | jq -s '.')
    else
        unmapped_comments="[]"
    fi

    # Build drift summary
    local drift_summary="${remapped_count} comments remapped, ${unmapped_count} unmapped"

    jq -n \
        --arg review_commit "${review_commit}" \
        --arg current_commit "${current_commit}" \
        --argjson comments "${remapped_comments}" \
        --argjson unmapped_comments "${unmapped_comments}" \
        --arg drift_summary "${drift_summary}" \
        '{
            drift_detected: true,
            review_commit: $review_commit,
            current_commit: $current_commit,
            comments: $comments,
            unmapped_comments: $unmapped_comments,
            drift_summary: $drift_summary
        }'
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
