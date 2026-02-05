#!/usr/bin/env bash
# create-draft-review.sh - Create a pending GitHub PR review with inline comments
#
# Creates a pending (draft) review on GitHub with inline comments. If a pending
# review already exists from the same user, it deletes the existing review and
# creates a fresh one with the new comments.
#
# Usage:
#   echo '<json_input>' | create-draft-review.sh
#
# Input JSON:
#   {
#     "owner": "org",
#     "repo": "repo",
#     "pr_number": 123,
#     "reviewer_username": "haacked",
#     "summary": "Overall review summary...",
#     "comments": [
#       {"path": "src/auth.ts", "position": 23, "body": "Consider..."},
#       {"path": "src/utils.ts", "position": 15, "body": "This could..."}
#     ],
#     "unmapped_comments": [
#       {"description": "Test coverage could be improved for X, Y, Z"}
#     ]
#   }
#
# Output JSON:
#   {
#     "success": true,
#     "review_id": 12345,
#     "review_url": "https://github.com/org/repo/pull/123#pullrequestreview-12345",
#     "inline_count": 5,
#     "summary_count": 2,
#     "replaced_existing": true
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=lib/helpers/json-helpers.sh
source "${SCRIPT_DIR}/helpers/json-helpers.sh"

# Validate a required field
# Args: $1 = value, $2 = field name
# Output: JSON error if invalid, returns 1 if invalid
require_field() {
    local value="$1"
    local name="$2"

    if [[ -z "${value}" ]] || [[ "${value}" == "null" ]]; then
        jq -n --arg name "${name}" '{success: false, error: ("Missing " + $name)}'
        return 1
    fi
}

# Fetch existing pending review and its comments
# Args: $1 = owner, $2 = repo, $3 = pr_number, $4 = reviewer_username
# Output: JSON with review_id and comments, or null if no pending review
get_existing_pending_review() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local reviewer="$4"

    # Get all reviews for this PR
    local reviews
    reviews=$(gh api "repos/${owner}/${repo}/pulls/${pr_number}/reviews" --paginate 2>/dev/null || echo "[]")

    # Find pending review from this user
    local pending_review
    pending_review=$(echo "${reviews}" | jq -r --arg user "${reviewer}" \
        '[.[] | select(.state == "PENDING" and .user.login == $user)] | first // null')

    if [[ "${pending_review}" == "null" ]]; then
        echo "null"
        return
    fi

    local review_id
    review_id=$(echo "${pending_review}" | jq -r '.id')

    # Fetch comments for this pending review
    local comments
    comments=$(gh api "repos/${owner}/${repo}/pulls/${pr_number}/reviews/${review_id}/comments" --paginate 2>/dev/null || echo "[]")

    # Return review info with comments
    jq -n \
        --argjson review "${pending_review}" \
        --argjson comments "${comments}" \
        '{
            review_id: $review.id,
            body: $review.body,
            comments: [$comments[] | {
                id: .id,
                path: .path,
                line: (.line // .original_line // .position),
                position: .position,
                body: .body
            }]
        }'
}

# Delete a pending review
# Args: $1 = owner, $2 = repo, $3 = pr_number, $4 = review_id
delete_pending_review() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local review_id="$4"

    gh api --method DELETE "repos/${owner}/${repo}/pulls/${pr_number}/reviews/${review_id}" 2>/dev/null || {
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
    trap "rm -f '${tmpfile}'" RETURN

    # Always include the comments array (even if empty) to ensure the review
    # stays in PENDING state. Without the comments field, GitHub immediately
    # submits the review as COMMENTED.
    local request_body
    request_body=$(jq -n \
        --arg body "${body}" \
        --argjson comments "${comments_json}" \
        '{body: $body, comments: $comments}')

    if ! result=$(echo "${request_body}" | gh api --method POST \
        "repos/${owner}/${repo}/pulls/${pr_number}/reviews" \
        --input - 2>"${tmpfile}"); then
        error_output=$(<"${tmpfile}")
        echo "API error: ${error_output}" >&2
        echo "Request body sent:" >&2
        echo "${request_body}" | jq -c '.' >&2
        return 1
    fi

    echo "${result}"
}

main() {
    # Read input JSON from stdin
    local input
    input=$(cat)

    # Validate input
    validate_json "${input}" || exit 1

    # Extract fields
    local owner repo pr_number reviewer summary comments unmapped_comments
    owner=$(echo "${input}" | jq -r '.owner')
    repo=$(echo "${input}" | jq -r '.repo')
    pr_number=$(echo "${input}" | jq -r '.pr_number')
    reviewer=$(echo "${input}" | jq -r '.reviewer_username')
    summary=$(echo "${input}" | jq -r '.summary // ""')
    comments=$(echo "${input}" | jq -c '.comments // []')

    # Validate comments have required fields and filter out invalid ones
    local valid_comments invalid_count
    valid_comments=$(echo "${comments}" | jq -c '[.[] | select(.path != null and .position != null and .body != null)]')
    invalid_count=$(echo "${comments}" | jq '[.[] | select(.path == null or .position == null or .body == null)] | length')

    if [[ "${invalid_count}" -gt 0 ]]; then
        warning "${invalid_count} comments filtered out due to missing path, position, or body"
        echo "Filtered comments:" >&2
        echo "${comments}" | jq -c '.[] | select(.path == null or .position == null or .body == null)' >&2
    fi

    # Use validated comments
    comments="${valid_comments}"
    unmapped_comments=$(echo "${input}" | jq -c '.unmapped_comments // []')

    # Validate required fields
    require_field "${owner}" "owner" || exit 1
    require_field "${repo}" "repo" || exit 1
    require_field "${pr_number}" "pr_number" || exit 1
    require_field "${reviewer}" "reviewer_username" || exit 1

    # Check for existing pending review
    local existing_review
    existing_review=$(get_existing_pending_review "${owner}" "${repo}" "${pr_number}" "${reviewer}")

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

    # Return success result
    jq -n \
        --argjson success true \
        --argjson review_id "${review_id}" \
        --arg review_url "${review_url}" \
        --argjson inline_count "${inline_count}" \
        --argjson summary_count "${unmapped_count}" \
        --argjson replaced_existing "${replaced_existing}" \
        '{
            success: $success,
            review_id: $review_id,
            review_url: $review_url,
            inline_count: $inline_count,
            summary_count: $summary_count,
            replaced_existing: $replaced_existing
        }'
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
