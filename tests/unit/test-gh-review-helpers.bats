#!/usr/bin/env bats
# Tests for helpers/gh-review-helpers.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    source "$PROJECT_ROOT/skills/review-code/scripts/helpers/gh-review-helpers.sh"

    # Every real caller sources this under its own `set -euo pipefail`, which
    # is what turns a failed gh call inside the pipe into a nonzero return.
    # gh-review-helpers.sh deliberately doesn't set this itself (a sourced
    # library shouldn't change the sourcer's shell options), so the test
    # harness sets it instead.
    set -o pipefail
}

# =============================================================================
# fetch_review_threads: the GraphQL pagination shared by pr-context.sh and
# resolve-review-threads.sh
# =============================================================================

@test "fetch_review_threads: uses graphql" {
    local body
    body="$(declare -f fetch_review_threads)"
    [[ "$body" == *"graphql"* ]]
}

@test "fetch_review_threads: delegates pagination to gh --paginate" {
    local body
    body="$(declare -f fetch_review_threads)"
    [[ "$body" == *"--paginate"* ]]
}

@test "fetch_review_threads: query names its cursor \$endCursor" {
    # gh's --paginate re-issues a GraphQL query with $endCursor set to the
    # previous page's cursor; any other variable name is silently never paged.
    local body
    body="$(declare -f fetch_review_threads)"
    [[ "$body" == *'after: $endCursor'* ]]
}

@test "fetch_review_threads: flattens each thread's first comment" {
    gh() {
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{
            "nodes":[
                {"id":"NODE1","isResolved":true,"isOutdated":false,"path":"a.py","line":10,"comments":{"nodes":[{"databaseId":4,"body":"a note","author":{"login":"eve"}}]}}
            ],
            "pageInfo":{"hasNextPage":false,"endCursor":null}
        }}}}}'
    }
    run fetch_review_threads owner repo 42
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0] == {id: "NODE1", isResolved: true, isOutdated: false, path: "a.py", line: 10, commentId: 4, author: "eve", body: "a note"}'
}

@test "fetch_review_threads: merges multiple pages into one array" {
    # A real --paginate call streams one JSON document per page to stdout from
    # a single gh invocation; a bash stub can't drive gh's own re-request
    # loop, so this mock reproduces that output shape directly instead of
    # trying to simulate the loop.
    gh() {
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"N1","isResolved":true,"isOutdated":false,"path":"a.py","line":1,"comments":{"nodes":[{"databaseId":1,"body":"one","author":{"login":"eve"}}]}}],"pageInfo":{"hasNextPage":true,"endCursor":"NEXT"}}}}}}'
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"N2","isResolved":false,"isOutdated":false,"path":"b.py","line":2,"comments":{"nodes":[{"databaseId":2,"body":"two","author":{"login":"frank"}}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
    }
    run fetch_review_threads owner repo 42
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'length == 2'
    echo "$output" | jq -e '.[0].commentId == 1 and .[1].commentId == 2'
}

@test "fetch_review_threads: a thread with no comments gets a null commentId and author" {
    gh() {
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{
            "nodes":[{"id":"NODE1","isResolved":false,"isOutdated":false,"path":"a.py","line":10,"comments":{"nodes":[]}}],
            "pageInfo":{"hasNextPage":false,"endCursor":null}
        }}}}}'
    }
    run fetch_review_threads owner repo 42
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].commentId == null and .[0].author == null and .[0].body == ""'
}

@test "fetch_review_threads: fails non-zero on a GraphQL error" {
    # The real gh binary exits non-zero whenever a GraphQL response body
    # carries an errors array, even alongside a 200 response.
    gh() { echo '{"errors":[{"message":"boom"}]}' >&2; return 1; }
    run fetch_review_threads owner repo 42
    [ "$status" -eq 1 ]
}
