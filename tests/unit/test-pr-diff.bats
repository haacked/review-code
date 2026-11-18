#!/usr/bin/env bats
# Tests for helpers/pr-diff.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    HELPERS="$PROJECT_ROOT/skills/review-code/scripts/helpers"
    export HELPERS

    load '../helpers/gh-stub.bash'
    install_default_gh_stub
    STUB_DIR="$GH_STUB_DIR"
    export STUB_DIR
    echo '[]' > "$STUB_DIR/files.json"
    echo 0 > "$STUB_DIR/changed_files"

    # `gh pr diff` prints $STUB_DIR/diff.out and exits with $STUB_DIR/diff.exit.
    # `gh api .../files` prints files.json, and `gh api .../pulls/N` prints changed_files.
    cat > "$STUB_DIR/gh" << 'STUB_EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_STUB_CALLS"
if [[ "$1 $2" == "pr diff" ]]; then
    cat "$STUB_DIR/diff.out"
    exit "$(cat "$STUB_DIR/diff.exit")"
fi
if [[ "$1" == "api" && "$*" == */files* ]]; then
    cat "$STUB_DIR/files.json"
    exit 0
fi
if [[ "$1" == "api" && "$*" == *changed_files* ]]; then
    cat "$STUB_DIR/changed_files"
    exit 0
fi
exit 1
STUB_EOF
}

teardown() {
    remove_gh_stub_dir
}

stub_diff_too_large() {
    cat > "$STUB_DIR/diff.out" << 'EOF'
could not find pull request diff: HTTP 406: Sorry, the diff exceeded the maximum number of files (300). Consider using 'List pull requests files' API or locally cloning the repository instead. (https://api.github.com/repos/o/r/pulls/7)
PullRequest.diff too_large
EOF
    echo 1 > "$STUB_DIR/diff.exit"
}

# Write $1 (a files API JSON array) as the stubbed file list and its length as changed_files.
stub_files() {
    echo "$1" > "$STUB_DIR/files.json"
    jq 'length' <<< "$1" > "$STUB_DIR/changed_files"
}

run_helper() {
    run bash -c "
        source '$HELPERS/error-helpers.sh'
        source '$HELPERS/gh-wrapper.sh'
        source '$HELPERS/git-diff-paths.sh'
        source '$HELPERS/pr-diff.sh'
        $1
    "
}

# =============================================================================
# fetch_pr_diff
# =============================================================================

@test "pr-diff: returns the diff endpoint's output when it succeeds" {
    printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' > "$STUB_DIR/diff.out"
    echo 0 > "$STUB_DIR/diff.exit"

    run_helper "fetch_pr_diff 7 o/r"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "diff --git a/x b/x" ]
    [ "${lines[5]}" = "+b" ]
    ! grep -q '^api' "$GH_STUB_CALLS"
}

@test "pr-diff: falls back to the files API when the diff is too large" {
    stub_diff_too_large
    stub_files '[{"filename":"src/a.ts","status":"modified","additions":1,"deletions":1,"patch":"@@ -1 +1 @@\n-old\n+new"}]'

    run_helper "fetch_pr_diff 7 o/r 2> '$STUB_DIR/stderr'"
    [ "$status" -eq 0 ]
    [ "$output" = $'diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1 +1 @@\n-old\n+new' ]
    grep -q "building the diff from the PR files API" "$STUB_DIR/stderr"
    grep -q 'repos/o/r/pulls/7/files?per_page=100' "$GH_STUB_CALLS"
}

@test "pr-diff: other diff endpoint failures fail without the fallback" {
    echo 'HTTP 404: Not Found' > "$STUB_DIR/diff.out"
    echo 1 > "$STUB_DIR/diff.exit"

    run_helper "fetch_pr_diff 7 o/r"
    [ "$status" -eq 1 ]
    [[ "$output" == *"HTTP 404"* ]]
    ! grep -q '^api' "$GH_STUB_CALLS"
}

@test "pr-diff: refuses when the files API returns fewer files than the PR changes" {
    stub_diff_too_large
    stub_files '[{"filename":"a","status":"modified","additions":1,"deletions":0,"patch":"@@ -0,0 +1 @@\n+x"}]'
    echo 3001 > "$STUB_DIR/changed_files"

    run_helper "fetch_pr_diff 7 o/r"
    [ "$status" -eq 1 ]
    [[ "$output" == *"returned 1 of the 3001 files"* ]]
    [[ "$output" != *"diff --git"* ]]
}

@test "pr-diff: warns about text files whose hunks GitHub omitted, not binary files" {
    stub_diff_too_large
    stub_files '[
        {"filename":"big file.json","status":"modified","additions":4000,"deletions":3900},
        {"filename":"icon.png","status":"added","additions":0,"deletions":0}
    ]'

    run_helper "fetch_pr_diff 7 o/r 2> '$STUB_DIR/stderr'"
    [ "$status" -eq 0 ]
    grep -q "GitHub omitted the diff" "$STUB_DIR/stderr"
    grep -qx '  big file.json' "$STUB_DIR/stderr"
    ! grep -q 'icon.png' "$STUB_DIR/stderr"
    [ "$output" = $'diff --git a/big file.json b/big file.json\ndiff --git a/icon.png b/icon.png' ]
}

# =============================================================================
# files_json_to_diff
# =============================================================================

@test "pr-diff: added and removed files use /dev/null on the missing side" {
    run_helper "files_json_to_diff <<< '[
        {\"filename\":\"new.ts\",\"status\":\"added\",\"patch\":\"@@ -0,0 +1 @@\n+a\"},
        {\"filename\":\"old.ts\",\"status\":\"removed\",\"patch\":\"@@ -1 +0,0 @@\n-a\"}
    ]'"
    [ "$status" -eq 0 ]
    [ "$output" = $'diff --git a/new.ts b/new.ts\n--- /dev/null\n+++ b/new.ts\n@@ -0,0 +1 @@\n+a\ndiff --git a/old.ts b/old.ts\ndeleted file mode 100644\n--- a/old.ts\n+++ /dev/null\n@@ -1 +0,0 @@\n-a' ]
}

@test "pr-diff: git_diff_paths marks removed files deleted even without hunks" {
    run_helper "
        files_json_to_diff <<< '[
            {\"filename\":\"logo.png\",\"status\":\"removed\",\"additions\":0,\"deletions\":0},
            {\"filename\":\"big.json\",\"status\":\"removed\",\"additions\":0,\"deletions\":90000},
            {\"filename\":\"kept.ts\",\"status\":\"modified\",\"additions\":1,\"deletions\":0,\"patch\":\"@@ -0,0 +1 @@\\n+a\"}
        ]' | git_diff_paths | tr '\\0' '\\t'
    "
    [ "$status" -eq 0 ]
    [ "$output" = $'true\tlogo.png\ttrue\tbig.json\tfalse\tkept.ts\t' ]
}

@test "pr-diff: renamed files carry rename lines, with hunks only when the content changed" {
    run_helper "files_json_to_diff <<< '[
        {\"filename\":\"b/new.ts\",\"previous_filename\":\"a/old.ts\",\"status\":\"renamed\"},
        {\"filename\":\"c.ts\",\"previous_filename\":\"d.ts\",\"status\":\"renamed\",\"patch\":\"@@ -1 +1 @@\n-x\n+y\n\"}
    ]'"
    [ "$status" -eq 0 ]
    [ "$output" = $'diff --git a/a/old.ts b/b/new.ts\nrename from a/old.ts\nrename to b/new.ts\ndiff --git a/d.ts b/c.ts\nrename from d.ts\nrename to c.ts\n--- a/d.ts\n+++ b/c.ts\n@@ -1 +1 @@\n-x\n+y' ]
}

@test "pr-diff: copied files carry copy lines" {
    run_helper "files_json_to_diff <<< '[{\"filename\":\"b.ts\",\"previous_filename\":\"a.ts\",\"status\":\"copied\"}]'"
    [ "$status" -eq 0 ]
    [ "$output" = $'diff --git a/a.ts b/b.ts\ncopy from a.ts\ncopy to b.ts' ]
}

@test "pr-diff: quotes paths the way git does" {
    local files
    files=$(jq -n '[
        {filename: "with space.ts", status: "added"},
        {filename: "quo\"te.ts", status: "added"},
        {filename: "back\\slash.ts", status: "added"},
        {filename: "tab\there.ts", status: "added"},
        {filename: "bell\u0007.ts", status: "added"},
        {filename: "esc\u001b.ts", status: "added"},
        {filename: "del\u007f.ts", status: "added"}
    ]')

    run_helper "files_json_to_diff <<< '$files'"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'diff --git a/with space.ts b/with space.ts' ]
    [ "${lines[1]}" = 'diff --git "a/quo\"te.ts" "b/quo\"te.ts"' ]
    [ "${lines[2]}" = 'diff --git "a/back\\slash.ts" "b/back\\slash.ts"' ]
    [ "${lines[3]}" = 'diff --git "a/tab\there.ts" "b/tab\there.ts"' ]
    [ "${lines[4]}" = 'diff --git "a/bell\a.ts" "b/bell\a.ts"' ]
    [ "${lines[5]}" = 'diff --git "a/esc\033.ts" "b/esc\033.ts"' ]
    [ "${lines[6]}" = 'diff --git "a/del\177.ts" "b/del\177.ts"' ]
}

@test "pr-diff: quoted paths match git's own diff output" {
    local repo
    repo=$(mktemp -d)
    git -C "$repo" init -q
    (cd "$repo" && touch "$(printf 'bell\a.ts')" 'quo"te.ts' 'back\slash.ts' "$(printf 'esc\033.ts')" 'with space.ts')
    git -C "$repo" add -A
    git -C "$repo" -c core.quotepath=false diff --cached | grep '^diff --git' > "$STUB_DIR/git-headers"

    local files
    files=$(git -C "$repo" ls-files -z | jq -Rs 'split("\u0000") | map(select(length > 0) | {filename: ., status: "added"})')
    rm -rf "$repo"

    echo "$files" > "$STUB_DIR/files.json"
    run_helper "files_json_to_diff < '$STUB_DIR/files.json'"
    [ "$status" -eq 0 ]
    diff "$STUB_DIR/git-headers" <(echo "$output")
}

@test "pr-diff: diff-position-mapper reads the rebuilt diff" {
    jq -n '[
        {filename: "src/new name.ts", previous_filename: "src/old.ts", status: "renamed", patch: "@@ -10,3 +10,4 @@ fn\n a\n-b\n+c\n+d\n e"}
    ]' > "$STUB_DIR/files.json"
    run_helper "files_json_to_diff < '$STUB_DIR/files.json'"
    local diff="$output"

    run bash -c "jq -n --arg diff \"\$1\" '{diff: \$diff, targets: [{path: \"src/new name.ts\", line: 12}, {path: \"src/new name.ts\", line: 11, side: \"LEFT\"}]}' | '$PROJECT_ROOT/skills/review-code/scripts/diff-position-mapper.sh'" _ "$diff"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.mappings[0] == {path: "src/new name.ts", line: 12, side: "RIGHT"}'
    echo "$output" | jq -e '.mappings[1] == {path: "src/new name.ts", line: 11, side: "LEFT"}'
}
