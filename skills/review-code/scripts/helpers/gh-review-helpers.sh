#!/usr/bin/env bash
# gh-review-helpers.sh - Read a PR's reviews and review threads.
#
# get_existing_pending_review is sourced by create-draft-review.sh, which uses
# it to decide whether to replace an existing pending review, and by
# amend-pending-review.sh, which uses it to scope every reword and drop to the
# caller's own pending review. fetch_review_threads is sourced by
# resolve-review-threads.sh and pr-context.sh, which both page the same
# reviewThreads GraphQL connection and project its fields differently.
#
# Everything here is read-only. Callers that mutate keep their own delete and
# update functions, so a script that must not create or destroy a review can
# source this without gaining the ability to.

# Guard against being sourced more than once per process.
[[ -n "${_GH_REVIEW_HELPERS_SOURCED:-}" ]] && return
_GH_REVIEW_HELPERS_SOURCED=1

_GH_REVIEW_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/gh-wrapper.sh
source "${_GH_REVIEW_HELPERS_DIR}/gh-wrapper.sh"

# Fetch a user's pending review and its inline comments.
# Args: $1 = owner, $2 = repo, $3 = pr_number, $4 = reviewer_username
# Output: JSON with review_id and comments, or the string "null" if the user
#         has no pending review on this PR.
# Returns nonzero when either GitHub read fails.
#
# GitHub allows one pending review per user per PR, so `first` is the only one.
# Pending comments are absent from GET /pulls/{n}/comments and from
# GET /pulls/comments/{id} (both 404), so this endpoint is the only way to read
# them. They also come back with line and original_line null, carrying only
# position, which is why position is reported separately rather than folded
# into line.
get_existing_pending_review() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local reviewer="$4"

    # Get all reviews for this PR
    local reviews
    if ! reviews=$(gh api "repos/${owner}/${repo}/pulls/${pr_number}/reviews" --paginate 2> /dev/null); then
        return 1
    fi

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
    if ! comments=$(gh api "repos/${owner}/${repo}/pulls/${pr_number}/reviews/${review_id}/comments" --paginate 2> /dev/null); then
        return 1
    fi

    # Return review info with comments. node_id is what the GraphQL reword
    # mutation addresses; id is the REST id a delete needs.
    jq -n \
        --argjson review "${pending_review}" \
        --argjson comments "${comments}" \
        '{
            review_id: $review.id,
            body: $review.body,
            comments: [$comments[] | {
                id: .id,
                node_id: .node_id,
                path: .path,
                line: (.line // .original_line),
                position: .position,
                body: .body
            }]
        }'
}

# Fetch every review thread on a PR from the reviewThreads GraphQL connection.
# Args: $1 = owner, $2 = repo, $3 = pr_number
# Output: JSON array of flattened thread nodes: id, isResolved, isOutdated,
#         path, line, commentId, author, and the thread's first comment body
#         (untruncated; callers cap it to their own needs).
# Returns nonzero when the GraphQL fetch fails. Callers decide whether that
# failure is fatal and how to report it, since one caller (pr-context.sh)
# degrades to "every thread open" while the other (resolve-review-threads.sh)
# treats it as fatal.
#
# `gh api graphql --paginate` walks pageInfo{hasNextPage,endCursor} itself and
# re-issues the query with $endCursor set to the previous page's cursor — the
# variable must be named exactly $endCursor for gh to find it. It also treats
# a GraphQL `errors` array as a failure and exits non-zero, so no separate
# per-page error check is needed here.
# shellcheck disable=SC2016  # GraphQL document; $vars are GraphQL variables bound via -F/-f
fetch_review_threads() {
    local owner="$1" repo_name="$2" pr_number="$3"

    local query='
    query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $endCursor) {
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              comments(first: 1) {
                nodes {
                  databaseId
                  body
                  author { login }
                }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }'

    gh api graphql --paginate \
        -f query="${query}" \
        -F owner="${owner}" \
        -F repo="${repo_name}" \
        -F number="${pr_number}" \
        | jq -s '
            [ .[].data.repository.pullRequest.reviewThreads.nodes[]
              | {
                  id, isResolved, isOutdated, path, line,
                  commentId: (.comments.nodes[0].databaseId // null),
                  author: (.comments.nodes[0].author.login // null),
                  body: (.comments.nodes[0].body // "")
                }
            ]
        ' || return 1
}
