#!/usr/bin/env bats
# Tests for resolve-review-threads.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/resolve-review-threads.sh"

    MOCK_DIR=$(mktemp -d)
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$MOCK_DIR"
}

# Mock gh: resolves repo, returns a canned single-page reviewThreads response,
# and records resolveReviewThread mutations to $MOCK_DIR/resolved.log.
# Threads:
#   111  a.py:42  unresolved  outdated   author haacked
#   222  b.py:10  unresolved  current    author teammate
#   333  c.py:5   resolved    current    author haacked
create_mock_gh() {
    cat > "$MOCK_DIR/gh" << 'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"repo view"* ]]; then
    echo "owner/repo"
    exit 0
fi
if [[ "$args" == *"resolveReviewThread"* || "$args" == *"--silent"* ]]; then
    # Record the threadId being resolved
    for ((i=1;i<=$#;i++)); do
        if [[ "${!i}" == "threadId="* ]]; then
            echo "${!i#threadId=}" >> "${MOCK_RESOLVED_LOG}"
        fi
    done
    # Real `gh ... --silent` prints nothing on stdout; mirror that so the
    # script's JSON summary is the only thing on stdout.
    exit 0
fi
if [[ "$args" == *"graphql"* ]]; then
    cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{
  "nodes":[
    {"id":"NODE111","isResolved":false,"isOutdated":true,"path":"a.py","line":42,"comments":{"nodes":[{"databaseId":111,"body":"N+1 query here","author":{"login":"haacked"}}]}},
    {"id":"NODE222","isResolved":false,"isOutdated":false,"path":"b.py","line":10,"comments":{"nodes":[{"databaseId":222,"body":"human comment","author":{"login":"teammate"}}]}},
    {"id":"NODE333","isResolved":true,"isOutdated":false,"path":"c.py","line":5,"comments":{"nodes":[{"databaseId":333,"body":"old","author":{"login":"haacked"}}]}}
  ],
  "pageInfo":{"hasNextPage":false,"endCursor":null}
}}}}}
JSON
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/gh"
    MOCK_RESOLVED_LOG="$MOCK_DIR/resolved.log"
    : > "$MOCK_RESOLVED_LOG"
    export MOCK_RESOLVED_LOG
}

# =============================================================================
# Script structure
# =============================================================================

@test "resolve-review-threads: has correct shebang" {
    run bash -c "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
    [ "$status" -eq 0 ]
}

@test "resolve-review-threads: uses set -euo pipefail" {
    run bash -c "head -40 '$SCRIPT' | grep -q 'set -euo pipefail'"
    [ "$status" -eq 0 ]
}

@test "resolve-review-threads: query requests comment author login" {
    run bash -c "grep -q 'author { login }' '$SCRIPT'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Argument validation
# =============================================================================

@test "resolve-review-threads: --outdated and --all are mutually exclusive" {
    run "$SCRIPT" 123 --outdated --all
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot combine"* ]]
}

@test "resolve-review-threads: --comment-id rejects non-numeric id" {
    run "$SCRIPT" 123 --comment-id abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"numeric"* ]]
}

@test "resolve-review-threads: --author requires an argument" {
    run "$SCRIPT" 123 --author
    [ "$status" -ne 0 ]
    [[ "$output" == *"--author requires"* ]]
}

@test "resolve-review-threads: --help exits zero and prints usage" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# Filtering behavior (mocked gh)
# =============================================================================

@test "resolve-review-threads: --json list excludes resolved threads" {
    create_mock_gh
    run bash -c "'$SCRIPT' 123 --json 2>/dev/null"
    [ "$status" -eq 0 ]
    # Only the two unresolved threads (111, 222); the resolved 333 is excluded
    count=$(echo "$output" | jq '.threads | length')
    [ "$count" -eq 2 ]
    echo "$output" | jq -e '[.threads[].commentId] | index(333) == null'
}

@test "resolve-review-threads: --author scopes list to that author" {
    create_mock_gh
    run bash -c "'$SCRIPT' 123 --author haacked --json 2>/dev/null"
    [ "$status" -eq 0 ]
    count=$(echo "$output" | jq '.threads | length')
    [ "$count" -eq 1 ]
    [ "$(echo "$output" | jq -r '.threads[0].commentId')" -eq 111 ]
    # Full comment body is surfaced for the semantic re-flag comparison
    echo "$output" | jq -e '.threads[0] | has("body")'
}

@test "resolve-review-threads: author match is case-insensitive" {
    create_mock_gh
    run bash -c "'$SCRIPT' 123 --author HAACKED --json 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.threads | length')" -eq 1 ]
}

@test "resolve-review-threads: --comment-id resolves only the matching thread" {
    create_mock_gh
    run bash -c "'$SCRIPT' 123 --author haacked --comment-id 111 --json 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.resolvedCount')" -eq 1 ]
    # The resolved node id was recorded by the mock
    grep -q "NODE111" "$MOCK_DIR/resolved.log"
    ! grep -q "NODE222" "$MOCK_DIR/resolved.log"
}

@test "resolve-review-threads: --comment-id for a teammate thread resolves nothing under our author scope" {
    create_mock_gh
    # 222 belongs to teammate; with --author haacked it is out of scope
    run bash -c "'$SCRIPT' 123 --author haacked --comment-id 222 --json 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.resolvedCount')" -eq 0 ]
    [ ! -s "$MOCK_DIR/resolved.log" ]
}

@test "resolve-review-threads: --dry-run does not resolve" {
    create_mock_gh
    run bash -c "'$SCRIPT' 123 --author haacked --comment-id 111 --dry-run --json 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.dryRun')" = "true" ]
    [ ! -s "$MOCK_DIR/resolved.log" ]
}
