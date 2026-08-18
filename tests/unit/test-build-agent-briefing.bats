#!/usr/bin/env bats
# Tests for build-agent-briefing.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/build-agent-briefing.sh"

    export CLAUDE_SESSION_DIR="$BATS_TEST_TMPDIR/sessions"
    mkdir -p "$CLAUDE_SESSION_DIR/review-code"

    ARCH_FILE="$BATS_TEST_TMPDIR/arch.md"
    echo "This is test architectural context" > "$ARCH_FILE"
}

teardown() {
    rm -rf "$CLAUDE_SESSION_DIR"
}

# Build a session in the layout session-manager.sh actually uses:
# <SESSION_DIR>/review-code/<session-id>.json, with the diff on disk and the
# session JSON carrying only its path.
create_test_session() {
    local session_id="review-code-12345-1234567890"
    local cmd_dir="$CLAUDE_SESSION_DIR/review-code"
    local artifacts="$cmd_dir/artifacts-test"
    mkdir -p "$artifacts"

    printf '%s\n' \
        'diff --git a/test.ts b/test.ts' \
        'index abc..def 100644' \
        '--- a/test.ts' \
        '+++ b/test.ts' \
        '@@ -1,3 +1,3 @@' \
        ' line1' \
        '-old line' \
        '+new line' \
        ' line3' \
        'diff --git a/terraform/main.tf b/terraform/main.tf' \
        'index 111..222 100644' \
        '--- a/terraform/main.tf' \
        '+++ b/terraform/main.tf' \
        '@@ -1 +1,2 @@' \
        ' resource "x" {}' \
        '+resource "y" {}' \
        > "$artifacts/diff.patch"

    jq -n --arg dir "$artifacts" '{
        status: "ready",
        mode: "pr",
        artifacts_dir: $dir,
        diff_path: ($dir + "/diff.patch"),
        review_context: "This is test review context",
        commit_messages: "Test commit",
        file_metadata: {modified_files: [
            {path: "test.ts", is_infra_config: false},
            {path: "terraform/main.tf", is_infra_config: true}
        ]},
        pr: {
            number: 1,
            title: "Test PR Title",
            url: "https://example.com/1",
            author: "testuser",
            base: "main",
            head: "feature",
            state: "OPEN",
            body: "This is a test PR body",
            comments: {conversation: [{author: "testuser", body: "Test comment"}], reviews: [], inline: []}
        }
    }' > "$cmd_dir/$session_id.json"

    echo "$session_id"
}

# =============================================================================
# Script structure
# =============================================================================

@test "build-agent-briefing: has correct shebang" {
    run head -1 "$SCRIPT"
    [ "$output" = "#!/usr/bin/env bash" ]
}

@test "build-agent-briefing: uses set -euo pipefail" {
    run grep -q 'set -euo pipefail' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "build-agent-briefing: script exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "build-agent-briefing: requires session-id argument" {
    run "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "build-agent-briefing: rejects nonexistent session-id" {
    run "$SCRIPT" "review-code-0-0"
    [ "$status" -ne 0 ]
}

# =============================================================================
# Output files
# =============================================================================

@test "build-agent-briefing: creates briefing.md" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    [ "$status" -eq 0 ]
    [ -f "$output/briefing.md" ]
}

@test "build-agent-briefing: diff.patch is present for agents to read" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    [ "$status" -eq 0 ]
    [ -s "$output/diff.patch" ]
}

@test "build-agent-briefing: briefing.md contains PR title" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    grep -q "Test PR Title" "$output/briefing.md"
}

@test "build-agent-briefing: briefing.md contains architectural context" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    grep -q "This is test architectural context" "$output/briefing.md"
}

@test "build-agent-briefing: briefing.md contains review context" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    grep -q "This is test review context" "$output/briefing.md"
}

@test "build-agent-briefing: briefing.md carries the shared review instructions" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    grep -q "Accuracy Requirements" "$output/briefing.md"
}

@test "build-agent-briefing: briefing.md does NOT inline the diff" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    # The diff is a separate file on purpose; duplicating it here would undo the saving.
    run grep -c '^diff --git' "$output/briefing.md"
    [ "$output" -eq 0 ]
}

@test "build-agent-briefing: diff.patch contains the changed file" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    grep -q "test.ts" "$output/diff.patch"
}

# =============================================================================
# Area-scoped diffs
# =============================================================================

@test "build-agent-briefing: creates diff-infra-config.patch when infra files present" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness infra-config"
    [ -f "$output/diff-infra-config.patch" ]
    grep -q "terraform/main.tf" "$output/diff-infra-config.patch"
}

@test "build-agent-briefing: infra-config diff omits non-infra hunks but names them" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "infra-config"
    run grep -c '^diff --git' "$output/diff-infra-config.patch"
    [ "$output" -eq 1 ]
}

@test "build-agent-briefing: lists out-of-scope paths in the scoped diff" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "infra-config"
    grep -q "Other files changed in this PR" "$output/diff-infra-config.patch"
}

@test "build-agent-briefing: does not create scoped diffs for agents not running" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    [ ! -f "$output/diff-infra-config.patch" ]
    [ ! -f "$output/diff-frontend.patch" ]
}

# =============================================================================
# Contract with the caller
# =============================================================================

@test "build-agent-briefing: prints the artifacts directory to stdout" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    [ "$status" -eq 0 ]
    [ -d "$output" ]
}

@test "build-agent-briefing: accepts a session file path as well as an id" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$CLAUDE_SESSION_DIR/review-code/$id.json" --arch-context-file "$ARCH_FILE" --agents "correctness"
    [ "$status" -eq 0 ]
    [ -f "$output/briefing.md" ]
}

@test "build-agent-briefing: fails when the diff file is missing" {
    local id; id=$(create_test_session)
    rm -f "$CLAUDE_SESSION_DIR/review-code/artifacts-test/diff.patch"
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    # A silently empty briefing would make agents report no findings, which reads
    # exactly like clean code. It has to fail loudly instead.
    [ "$status" -ne 0 ]
}

@test "build-agent-briefing: fails when the diff file is empty" {
    local id; id=$(create_test_session)
    : > "$CLAUDE_SESSION_DIR/review-code/artifacts-test/diff.patch"
    run "$SCRIPT" "$id" --arch-context-file "$ARCH_FILE" --agents "correctness"
    [ "$status" -ne 0 ]
}

@test "build-agent-briefing: fails when the session has no artifacts_dir" {
    local id="review-code-999-999"
    echo '{"status":"ready","mode":"pr"}' > "$CLAUDE_SESSION_DIR/review-code/$id.json"
    run "$SCRIPT" "$id"
    [ "$status" -ne 0 ]
}

@test "build-agent-briefing: works without an architectural context file" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --agents "correctness"
    [ "$status" -eq 0 ]
    [ -s "$output/briefing.md" ]
}

@test "build-agent-briefing: --diff-file overrides the session diff" {
    local id; id=$(create_test_session)
    local delta="$BATS_TEST_TMPDIR/delta.patch"
    printf '%s\n' \
        'diff --git a/only.txt b/only.txt' \
        '--- a/only.txt' \
        '+++ b/only.txt' \
        '@@ -1 +1 @@' \
        '-a' \
        '+b' \
        > "$delta"
    run "$SCRIPT" "$id" --agents "correctness" --diff-file "$delta"
    [ "$status" -eq 0 ]
    # The incremental re-review path hands agents the delta, not the whole PR.
    grep -q "only.txt" "$delta"
    [ -s "$output/briefing.md" ]
}

@test "build-agent-briefing: fails when --diff-file points nowhere" {
    local id; id=$(create_test_session)
    run "$SCRIPT" "$id" --agents "correctness" --diff-file "$BATS_TEST_TMPDIR/absent.patch"
    [ "$status" -ne 0 ]
}
