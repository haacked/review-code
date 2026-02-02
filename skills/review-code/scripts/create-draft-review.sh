#!/usr/bin/env bash
# create-draft-review.sh - Create or amend a pending GitHub PR review with inline comments
#
# Creates a pending (draft) review on GitHub with inline comments. If a pending
# review already exists from the same user, it performs a smart merge:
# - Compares existing comments with new suggestions semantically
# - Keeps comments that still apply (using new wording)
# - Adds new comments not previously covered
# - Removes outdated comments
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
#     "amended": true,
#     "kept_comments": 3,
#     "new_comments": 2,
#     "removed_comments": 1
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"

# Calculate word-based similarity between two strings (0-100)
# Uses Jaccard similarity on word sets
# Args: $1 = text1, $2 = text2
# Output: Similarity percentage (0-100)
calculate_similarity() {
    local text1="$1"
    local text2="$2"

    # Normalize: lowercase, remove punctuation, split to words
    local words1 words2
    words1=$(echo "${text1}" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | grep -v '^$' || true)
    words2=$(echo "${text2}" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | grep -v '^$' || true)

    # Handle empty cases
    if [[ -z "${words1}" ]] && [[ -z "${words2}" ]]; then
        echo "100"
        return
    fi
    if [[ -z "${words1}" ]] || [[ -z "${words2}" ]]; then
        echo "0"
        return
    fi

    # Count common words and total unique words
    local common total_unique
    common=$(comm -12 <(echo "${words1}") <(echo "${words2}") | wc -l | tr -d ' ')
    total_unique=$(cat <(echo "${words1}") <(echo "${words2}") | sort -u | wc -l | tr -d ' ')

    # Jaccard similarity: intersection / union
    if [[ "${total_unique}" -eq 0 ]]; then
        echo "0"
    else
        echo $(( (common * 100) / total_unique ))
    fi
}

# Check if two comments match semantically
# Args: $1 = existing comment JSON, $2 = new comment JSON
# Output: "true" if match, "false" otherwise
comments_match() {
    local existing="$1"
    local new="$2"

    # Extract fields
    local existing_path existing_line existing_body
    local new_path new_position new_body

    existing_path=$(echo "${existing}" | jq -r '.path')
    existing_line=$(echo "${existing}" | jq -r '.line // .position // 0')
    existing_body=$(echo "${existing}" | jq -r '.body')

    new_path=$(echo "${new}" | jq -r '.path')
    new_position=$(echo "${new}" | jq -r '.position // 0')
    new_body=$(echo "${new}" | jq -r '.body')

    # Must be same file
    if [[ "${existing_path}" != "${new_path}" ]]; then
        echo "false"
        return
    fi

    # Line must be within ±5 lines
    local line_diff=$(( existing_line - new_position ))
    if [[ ${line_diff} -lt 0 ]]; then
        line_diff=$(( -line_diff ))
    fi
    if [[ ${line_diff} -gt 5 ]]; then
        echo "false"
        return
    fi

    # Content similarity must be > 60%
    local similarity
    similarity=$(calculate_similarity "${existing_body}" "${new_body}")
    if [[ ${similarity} -ge 60 ]]; then
        echo "true"
    else
        echo "false"
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

    local result
    if [[ "${comments_json}" == "[]" ]]; then
        # No inline comments, just create review with body
        result=$(gh api --method POST "repos/${owner}/${repo}/pulls/${pr_number}/reviews" \
            -f body="${body}" 2>&1) || {
            echo "${result}" >&2
            return 1
        }
    else
        # Create review with inline comments
        # Build the request body as JSON and use stdin
        local request_body
        request_body=$(jq -n \
            --arg body "${body}" \
            --argjson comments "${comments_json}" \
            '{body: $body, comments: $comments}')

        result=$(echo "${request_body}" | gh api --method POST "repos/${owner}/${repo}/pulls/${pr_number}/reviews" \
            --input - 2>&1) || {
            echo "${result}" >&2
            return 1
        }
    fi

    echo "${result}"
}

main() {
    # Read input JSON from stdin
    local input
    input=$(cat)

    # Validate input
    if ! echo "${input}" | jq empty 2>/dev/null; then
        error "Invalid JSON input"
        exit 1
    fi

    # Extract fields
    local owner repo pr_number reviewer summary comments unmapped_comments
    owner=$(echo "${input}" | jq -r '.owner')
    repo=$(echo "${input}" | jq -r '.repo')
    pr_number=$(echo "${input}" | jq -r '.pr_number')
    reviewer=$(echo "${input}" | jq -r '.reviewer_username')
    summary=$(echo "${input}" | jq -r '.summary // ""')
    comments=$(echo "${input}" | jq -c '.comments // []')
    unmapped_comments=$(echo "${input}" | jq -c '.unmapped_comments // []')

    # Validate required fields
    if [[ -z "${owner}" ]] || [[ "${owner}" == "null" ]]; then
        jq -n '{success: false, error: "Missing owner"}'
        exit 1
    fi
    if [[ -z "${repo}" ]] || [[ "${repo}" == "null" ]]; then
        jq -n '{success: false, error: "Missing repo"}'
        exit 1
    fi
    if [[ -z "${pr_number}" ]] || [[ "${pr_number}" == "null" ]]; then
        jq -n '{success: false, error: "Missing pr_number"}'
        exit 1
    fi
    if [[ -z "${reviewer}" ]] || [[ "${reviewer}" == "null" ]]; then
        jq -n '{success: false, error: "Missing reviewer_username"}'
        exit 1
    fi

    # Check for existing pending review
    local existing_review
    existing_review=$(get_existing_pending_review "${owner}" "${repo}" "${pr_number}" "${reviewer}")

    local amended="false"
    local kept_count=0
    local new_count=0
    local removed_count=0
    local merged_comments="${comments}"

    if [[ "${existing_review}" != "null" ]]; then
        # Smart merge with existing review
        amended="true"
        local existing_comments
        existing_comments=$(echo "${existing_review}" | jq -c '.comments // []')
        local existing_review_id
        existing_review_id=$(echo "${existing_review}" | jq -r '.review_id')

        # Compare and categorize
        local new_comments_arr="[]"
        local kept_comments_arr="[]"

        # For each new comment, check if it matches an existing one
        while IFS= read -r new_comment; do
            local found_match="false"
            while IFS= read -r existing_comment; do
                if [[ $(comments_match "${existing_comment}" "${new_comment}") == "true" ]]; then
                    found_match="true"
                    # Use new comment (fresher wording)
                    kept_comments_arr=$(echo "${kept_comments_arr}" | jq --argjson c "${new_comment}" '. + [$c]')
                    break
                fi
            done < <(echo "${existing_comments}" | jq -c '.[]')

            if [[ "${found_match}" == "false" ]]; then
                new_comments_arr=$(echo "${new_comments_arr}" | jq --argjson c "${new_comment}" '. + [$c]')
            fi
        done < <(echo "${comments}" | jq -c '.[]')

        kept_count=$(echo "${kept_comments_arr}" | jq 'length')
        new_count=$(echo "${new_comments_arr}" | jq 'length')

        # Count removed (existing comments with no match in new)
        local existing_count
        existing_count=$(echo "${existing_comments}" | jq 'length')
        removed_count=$(( existing_count - kept_count ))
        if [[ ${removed_count} -lt 0 ]]; then
            removed_count=0
        fi

        # Merge: kept + new
        merged_comments=$(echo "${kept_comments_arr}" | jq --argjson new "${new_comments_arr}" '. + $new')

        # Delete existing pending review
        if ! delete_pending_review "${owner}" "${repo}" "${pr_number}" "${existing_review_id}"; then
            warning "Proceeding without deleting existing review…"
        fi
    else
        # No existing review, all comments are new
        new_count=$(echo "${comments}" | jq 'length')
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

    # Add note about removed comments if any
    if [[ ${removed_count} -gt 0 ]]; then
        review_body="${review_body}

*Note: ${removed_count} previous draft comment(s) were removed as they no longer apply.*"
    fi

    # Create the pending review
    local create_result
    create_result=$(create_pending_review "${owner}" "${repo}" "${pr_number}" "${review_body}" "${merged_comments}") || {
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
    inline_count=$(echo "${merged_comments}" | jq 'length')

    # Return success result
    jq -n \
        --argjson success true \
        --argjson review_id "${review_id}" \
        --arg review_url "${review_url}" \
        --argjson inline_count "${inline_count}" \
        --argjson summary_count "${unmapped_count}" \
        --argjson amended "$(echo "${amended}" | jq -R 'if . == "true" then true else false end')" \
        --argjson kept_comments "${kept_count}" \
        --argjson new_comments "${new_count}" \
        --argjson removed_comments "${removed_count}" \
        '{
            success: $success,
            review_id: $review_id,
            review_url: $review_url,
            inline_count: $inline_count,
            summary_count: $summary_count,
            amended: $amended,
            kept_comments: $kept_comments,
            new_comments: $new_comments,
            removed_comments: $removed_comments
        }'
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
