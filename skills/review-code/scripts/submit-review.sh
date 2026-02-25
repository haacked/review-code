#!/usr/bin/env bash
# submit-review.sh - Submit a pending GitHub PR review
#
# Submits an existing pending (draft) review on GitHub with a specified event
# type. Verifies the review is in PENDING state before submitting to prevent
# double-submission.
#
# Usage:
#   echo '<json_input>' | submit-review.sh
#
# Input JSON:
#   {
#     "owner": "org",
#     "repo": "repo",
#     "pr_number": 123,
#     "review_id": 12345,
#     "event": "COMMENT"
#   }
#
# Event accepts: APPROVE, REQUEST_CHANGES, COMMENT
#
# Output JSON:
#   {
#     "success": true,
#     "review_id": 12345,
#     "review_url": "https://github.com/org/repo/pull/123#pullrequestreview-12345",
#     "event": "COMMENT",
#     "state": "COMMENTED"
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/error-helpers.sh
source "${SCRIPT_DIR}/helpers/error-helpers.sh"
# shellcheck source=helpers/json-helpers.sh
source "${SCRIPT_DIR}/helpers/json-helpers.sh"
# shellcheck source=helpers/gh-wrapper.sh
source "${SCRIPT_DIR}/helpers/gh-wrapper.sh"

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

# Validate the event is one of the allowed values
# Args: $1 = event
# Output: JSON error if invalid, returns 1 if invalid
validate_event() {
    local event="$1"

    case "${event}" in
        APPROVE | REQUEST_CHANGES | COMMENT) return 0 ;;
        *)
            jq -n --arg event "${event}" \
                '{success: false, error: ("Invalid event: " + $event + ". Must be APPROVE, REQUEST_CHANGES, or COMMENT")}'
            return 1
            ;;
    esac
}

# Verify the review is in PENDING state
# Args: $1 = owner, $2 = repo, $3 = pr_number, $4 = review_id
# Output: JSON error if not pending, returns 1 if not pending
verify_pending_state() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local review_id="$4"

    local review
    review=$(gh api "repos/${owner}/${repo}/pulls/${pr_number}/reviews/${review_id}" 2>/dev/null) || {
        jq -n --arg id "${review_id}" \
            '{success: false, error: ("Failed to fetch review " + $id)}'
        return 1
    }

    local state
    state=$(echo "${review}" | jq -r '.state')

    if [[ "${state}" != "PENDING" ]]; then
        jq -n --arg id "${review_id}" --arg state "${state}" \
            '{success: false, error: ("Review " + $id + " is in " + $state + " state, not PENDING. It may have already been submitted.")}'
        return 1
    fi
}

# Submit the review
# Args: $1 = owner, $2 = repo, $3 = pr_number, $4 = review_id, $5 = event
# Output: API response JSON
submit_review() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local review_id="$4"
    local event="$5"

    local request_body
    request_body=$(jq -n --arg event "${event}" '{event: $event}')

    local result
    result=$(echo "${request_body}" | gh api --method POST \
        "repos/${owner}/${repo}/pulls/${pr_number}/reviews/${review_id}/events" \
        --input - 2>/dev/null) || {
        echo "Failed to submit review" >&2
        return 1
    }

    echo "${result}"
}

main() {
    # Read input JSON from stdin
    local input
    input=$(cat)

    # Validate input
    validate_json "${input}" || exit 1

    # Extract fields
    local owner repo pr_number review_id event
    owner=$(echo "${input}" | jq -r '.owner')
    repo=$(echo "${input}" | jq -r '.repo')
    pr_number=$(echo "${input}" | jq -r '.pr_number')
    review_id=$(echo "${input}" | jq -r '.review_id')
    event=$(echo "${input}" | jq -r '.event')

    # Validate required fields
    require_field "${owner}" "owner" || exit 1
    require_field "${repo}" "repo" || exit 1
    require_field "${pr_number}" "pr_number" || exit 1
    require_field "${review_id}" "review_id" || exit 1
    require_field "${event}" "event" || exit 1

    # Validate event value
    validate_event "${event}" || exit 1

    # Verify the review is in PENDING state
    verify_pending_state "${owner}" "${repo}" "${pr_number}" "${review_id}" || exit 1

    # Submit the review
    local submit_result
    submit_result=$(submit_review "${owner}" "${repo}" "${pr_number}" "${review_id}" "${event}") || {
        jq -n \
            --arg error "Failed to submit review: ${submit_result}" \
            '{success: false, error: $error}'
        exit 1
    }

    # Extract state from API response
    local state
    state=$(echo "${submit_result}" | jq -r '.state')

    # Build review URL
    local review_url="https://github.com/${owner}/${repo}/pull/${pr_number}#pullrequestreview-${review_id}"

    # Return success result
    jq -n \
        --argjson success true \
        --argjson review_id "${review_id}" \
        --arg review_url "${review_url}" \
        --arg event "${event}" \
        --arg state "${state}" \
        '{
            success: $success,
            review_id: $review_id,
            review_url: $review_url,
            event: $event,
            state: $state
        }'
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
