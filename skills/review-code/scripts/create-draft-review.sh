#!/usr/bin/env bash
set -euo pipefail
# create-draft-review.sh - Create a pending GitHub PR review with inline comments
#
# Creates a pending (draft) review on GitHub with inline comments. If a pending
# review already exists from the same user, it deletes the existing review and
# creates a fresh one with the new comments.
#
# Usage:
#   echo '<json_input>' | create-draft-review.sh
#   create-draft-review.sh < review.json
#
# The script rejects all command-line arguments.
#
# Input JSON:
#   {
#     "owner": "org",
#     "repo": "repo",
#     "pr_number": 123,
#     "reviewer_username": "haacked",
#     "summary": "Overall review summary...",
#     "review_commit": "abc123...",           (optional: enables drift detection)
#     "original_diff": "diff --git ...",      (optional: original diff for content matching)
#     "original_diff_path": "/path/diff.patch",  (optional: same diff as a file, preferred)
#     "review_file": "/path/pr-123.md",       (optional: records each posted comment's
#                                              id in that file, so a later session can
#                                              reword one comment instead of re-reviewing)
#     "append": true,                         (optional: retain pending comments outside the delta)
#     "delta_paths": ["src/changed.ts"],       (required when append is true)
#     "comments": [
#       {"path": "src/auth.ts", "line": 42, "side": "RIGHT", "body": "Consider...", "line_content": "    some_code()"},
#       {"path": "src/utils.ts", "line": 15, "side": "RIGHT", "body": "This could..."}
#     ],
#     "unmapped_comments": [
#       {"description": "Test coverage could be improved for X, Y, Z"}
#     ]
#   }
#
# Comments can carry source_line when their posting line differs from the
# finding heading. This field is local metadata and is not sent to GitHub.
#
# Output JSON:
#   {
#     "success": true,
#     "review_id": 12345,
#     "review_url": "https://github.com/org/repo/pull/123#pullrequestreview-12345",
#     "inline_count": 5,
#     "summary_count": 2,
#     "replaced_existing": true,
#     "drift_detected": false,
#     "annotated_count": 5                    (comments whose id was recorded in review_file)
#   }
#
# If the review is created but its comment ids cannot all be recorded, the
# script exits nonzero and returns the created review metadata:
#   {
#     "success": false,
#     "error": "...",
#     "review_id": 12345,
#     "review_url": "https://github.com/org/repo/pull/123#pullrequestreview-12345",
#     "inline_count": 5,
#     "annotated_count": 4
#   }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=lib/helpers/json-helpers.sh
source "${SCRIPT_DIR}/helpers/json-helpers.sh"
# shellcheck source=lib/helpers/gh-wrapper.sh
source "${SCRIPT_DIR}/helpers/gh-wrapper.sh"
# shellcheck source=helpers/gh-review-helpers.sh
source "${SCRIPT_DIR}/helpers/gh-review-helpers.sh"

# Delete a pending review
# Args: $1 = owner, $2 = repo, $3 = pr_number, $4 = review_id
delete_pending_review() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local review_id="$4"

    gh api --method DELETE "repos/${owner}/${repo}/pulls/${pr_number}/reviews/${review_id}" > /dev/null 2>&1 || {
        warning "Failed to delete existing pending review ${review_id}"
        return 1
    }
}

# Create a new pending review
# Args: $1 = owner, $2 = repo, $3 = pr_number, $4 = body, $5 = comments_json
# Output: JSON with review result
create_pending_review() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local body="$4"
    local comments_json="$5"

    local result error_output
    local tmpfile
    tmpfile=$(mktemp)
    # shellcheck disable=SC2064  # expand tmpfile now so the trap removes this call's file
    trap "rm -f '${tmpfile}'" RETURN

    # Always use JSON format with comments array for consistency, whether
    # comments are empty or not. This ensures uniform API request structure
    # and predictable error handling.
    local request_body
    request_body=$(jq -n \
        --arg body "${body}" \
        --argjson comments "${comments_json}" \
        '{body: $body, comments: [$comments[] |
            if .position != null then {path, position, body}
            else {path, line, body} + (if .side then {side} else {} end)
            end]}')

    if ! result=$(echo "${request_body}" | gh api --method POST \
        "repos/${owner}/${repo}/pulls/${pr_number}/reviews" \
        --input - 2> "${tmpfile}"); then
        error_output=$(< "${tmpfile}")
        echo "API error: ${error_output}" >&2
        echo "Request body sent:" >&2
        echo "${request_body}" | jq -c '.' >&2
        return 1
    fi

    echo "${result}"
}

main() {
    if [[ $# -gt 0 ]]; then
        error "This script accepts no command-line arguments. Pass review JSON on stdin."
        echo "Usage: create-draft-review.sh < review.json" >&2
        exit 2
    fi

    # Read input JSON from stdin
    local input
    input=$(cat)

    # Validate input
    validate_json "${input}" || exit 1

    # Extract fields
    local owner repo pr_number reviewer summary comments unmapped_comments review_commit review_file append delta_paths
    owner=$(echo "${input}" | jq -r '.owner')
    repo=$(echo "${input}" | jq -r '.repo')
    pr_number=$(echo "${input}" | jq -r '.pr_number')
    reviewer=$(echo "${input}" | jq -r '.reviewer_username')
    summary=$(echo "${input}" | jq -r '.summary // ""')
    review_commit=$(echo "${input}" | jq -r '.review_commit // ""')
    review_file=$(echo "${input}" | jq -r '.review_file // ""')
    comments=$(echo "${input}" | jq -c '[.comments // [] | .[] |
        . + {source_line: (.source_line // .original_line // .line)}]')
    unmapped_comments=$(echo "${input}" | jq -c '.unmapped_comments // []')
    append=$(echo "${input}" | jq -r '.append // false')
    delta_paths=$(echo "${input}" | jq -c '.delta_paths // []')

    # Validate required fields early, before any network calls
    require_field "${owner}" "owner" || exit 1
    require_field "${repo}" "repo" || exit 1
    require_field "${pr_number}" "pr_number" || exit 1
    require_field "${reviewer}" "reviewer_username" || exit 1

    # Run drift detection if review_commit is provided
    local drift_detected=false

    if [[ -n "${review_commit}" ]] && [[ "${review_commit}" != "null" ]]; then
        local drift_result
        if drift_result=$(echo "${input}" | jq --argjson comments "${comments}" '.comments = $comments' \
            | "${SCRIPT_DIR}/detect-comment-drift.sh"); then
            drift_detected=$(echo "${drift_result}" | jq -r '.drift_detected')

            if [[ "${drift_detected}" == "true" ]]; then
                local drift_summary
                drift_summary=$(echo "${drift_result}" | jq -r '.drift_summary // ""')
                warning "Comment drift detected: ${drift_summary}"

                # Replace comments with remapped versions
                comments=$(echo "${drift_result}" | jq -c '.comments // []')

                # Merge drift unmapped comments into the existing unmapped_comments
                local drift_unmapped
                drift_unmapped=$(echo "${drift_result}" | jq -c '.unmapped_comments // []')
                unmapped_comments=$(jq -n \
                    --argjson existing "${unmapped_comments}" \
                    --argjson drift "${drift_unmapped}" \
                    '$existing + $drift')
            fi
        else
            # Drift detection failed; proceed with original positions
            warning "Drift detection failed, using original comment positions"
        fi
    fi

    # Check for an existing pending review before validation so append reviews can
    # retain its comments on files outside the delta.
    local existing_review
    if ! existing_review=$(get_existing_pending_review "${owner}" "${repo}" "${pr_number}" "${reviewer}"); then
        jq -n '{success: false, error: "Failed to read the existing pending review"}'
        exit 1
    fi

    if [[ "${append}" == "true" ]]; then
        if [[ "$(echo "${delta_paths}" | jq -r 'type')" != "array" ]] || [[ "$(echo "${delta_paths}" | jq 'length')" -eq 0 ]]; then
            error "Append draft input requires a non-empty delta_paths array"
            exit 1
        fi
        if [[ "${existing_review}" != "null" ]]; then
            local preserved_comments
            preserved_comments=$(jq -n \
                --argjson review "${existing_review}" \
                --argjson delta_paths "${delta_paths}" \
                '[
                    $review.comments[]
                    | select(.path as $path | ($delta_paths | index($path) | not))
                    | {path, body, source_id: .id}
                        + (if .position != null then {position} else {line} end)
                ]')
            comments=$(jq -n \
                --argjson preserved "${preserved_comments}" \
                --argjson current "${comments}" \
                '$preserved + $current')
        fi
    fi

    # Retain source locations through validation for annotation after posting.
    local validation_result
    validation_result=$(echo "${comments}" | jq -c '
        def is_non_empty_string:
            if type == "string" then length > 0 else false end;
        def is_positive_integer:
            if type == "number" then . > 0 and . == floor else false end;
        def is_valid:
            (.path | is_non_empty_string) and
            (.body | is_non_empty_string) and
            (if .position != null then
                (.position | is_positive_integer)
             else
                (.line | is_positive_integer) and
                (.side == null or .side == "LEFT" or .side == "RIGHT")
             end);
        {
            valid: [
                .[] | select(is_valid)
            ],
            invalid: [.[] | select(is_valid | not)]
        }')
    comments=$(echo "${validation_result}" | jq -c '.valid')
    local invalid_count
    invalid_count=$(echo "${validation_result}" | jq '.invalid | length')

    if [[ "${invalid_count}" -gt 0 ]]; then
        warning "${invalid_count} comments filtered out due to missing or invalid required fields"
        echo "Filtered comments:" >&2
        echo "${validation_result}" | jq -c '.invalid[]' >&2
    fi

    local replaced_existing="false"

    if [[ "${existing_review}" != "null" ]]; then
        # Delete existing pending review and replace with new one
        replaced_existing="true"
        local existing_review_id
        existing_review_id=$(echo "${existing_review}" | jq -r '.review_id')

        if ! delete_pending_review "${owner}" "${repo}" "${pr_number}" "${existing_review_id}"; then
            warning "Proceeding without deleting existing review…"
        fi
    fi

    # Build review body
    local review_body="${summary}"

    # Add unmapped comments to the body
    local unmapped_count
    unmapped_count=$(echo "${unmapped_comments}" | jq 'length')
    if [[ ${unmapped_count} -gt 0 ]]; then
        review_body="${review_body}

**Additional Notes:**
"
        while IFS= read -r unmapped; do
            local desc
            desc=$(echo "${unmapped}" | jq -r '.description // .body // .')
            review_body="${review_body}
- ${desc}"
        done < <(echo "${unmapped_comments}" | jq -c '.[]')
    fi

    # Create the pending review
    local create_result
    create_result=$(create_pending_review "${owner}" "${repo}" "${pr_number}" "${review_body}" "${comments}") || {
        jq -n \
            --arg error "Failed to create review: ${create_result}" \
            '{success: false, error: $error}'
        exit 1
    }

    # Extract review info from result
    local review_id review_url
    review_id=$(echo "${create_result}" | jq -r '.id')
    review_url="https://github.com/${owner}/${repo}/pull/${pr_number}#pullrequestreview-${review_id}"

    local inline_count
    inline_count=$(echo "${comments}" | jq 'length')

    # Return the created review metadata when annotation fails.
    local annotated_count=0 annotation_failure=""
    if [[ -n "${review_file}" ]]; then
        local posted_comments annotate_result submitted_file
        submitted_file=$(mktemp)
        # shellcheck disable=SC2064  # Keep the path after main's locals go out of scope.
        trap "rm -f '${submitted_file}'" EXIT
        echo "${comments}" > "${submitted_file}"
        posted_comments=$(gh api "repos/${owner}/${repo}/pulls/${pr_number}/reviews/${review_id}/comments" --paginate 2> /dev/null \
            | jq -s 'add // []' || echo "[]")
        annotate_result=$(echo "${posted_comments}" | "${SCRIPT_DIR}/review-comment-blocks.py" annotate \
            --review-file "${review_file}" \
            --submitted-comments "${submitted_file}" \
            --review-id "${review_id}" \
            --posted-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2> /dev/null || echo '{"error":"Comment annotation failed"}')
        annotated_count=$(echo "${annotate_result}" | jq -r '.annotated_comments // 0')
        local annotator_error
        annotator_error=$(echo "${annotate_result}" | jq -r '.error // ""')
        if [[ "${annotated_count}" -ne "${inline_count}" || -n "${annotator_error}" ]]; then
            annotation_failure="Draft review ${review_id} was created, but recorded comment ids for ${annotated_count} of ${inline_count} inline comments in ${review_file}. Repair the annotations before retrying."
            if [[ -n "${annotator_error}" ]]; then
                annotation_failure+=" ${annotator_error}"
            fi
            error "${annotation_failure}"
        fi
    fi

    jq -n \
        --arg error "${annotation_failure}" \
        --argjson annotated_count "${annotated_count}" \
        --argjson review_id "${review_id}" \
        --arg review_url "${review_url}" \
        --argjson inline_count "${inline_count}" \
        --argjson summary_count "${unmapped_count}" \
        --argjson replaced_existing "${replaced_existing}" \
        --argjson drift_detected "${drift_detected}" \
        '{
            success: ($error == ""),
            review_id: $review_id,
            review_url: $review_url,
            inline_count: $inline_count,
            summary_count: $summary_count,
            replaced_existing: $replaced_existing,
            drift_detected: $drift_detected,
            annotated_count: $annotated_count
        } + (if $error == "" then {} else {error: $error} end)'
    [[ -z "${annotation_failure}" ]]
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
