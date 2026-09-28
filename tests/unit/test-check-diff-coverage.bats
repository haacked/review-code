#!/usr/bin/env bats
# Tests for check-diff-coverage.sh
#
# The script exists because the truncation guard in the agent prompt is
# advisory: it only helps an agent that reads with Read and compares counts.
# These tests pin that both access paths are counted and that a short read is
# reported rather than passed over.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/check-diff-coverage.sh"

    ROOT="$BATS_TEST_TMPDIR/projects"
    SESSION="11111111-2222-3333-4444-555555555555"
    SUBS="$ROOT/some-project/$SESSION/subagents"
    mkdir -p "$SUBS"
}

# Write one subagent transcript. $1 agent type, $2 name, remaining args are
# tool_use blocks already rendered as JSON.
make_agent() {
    local atype="$1" name="$2"
    shift 2
    jq -n --arg t "$atype" '{agentType: $t}' > "$SUBS/$name.meta.json"
    : > "$SUBS/$name.jsonl"
    local block
    for block in "$@"; do
        jq -nc --argjson b "$block" '{message: {role: "assistant", content: [$b]}}' >> "$SUBS/$name.jsonl"
    done
}

read_block() { # $1 path, $2 offset (or null), $3 limit (or null)
    jq -nc --arg p "$1" --argjson o "$2" --argjson l "$3" \
        '{type: "tool_use", name: "Read", input: ({file_path: $p}
          + (if $o == null then {} else {offset: $o} end)
          + (if $l == null then {} else {limit: $l} end))}'
}

bash_block() { jq -nc --arg c "$1" '{type: "tool_use", name: "Bash", input: {command: $c}}'; }

run_cov() { run "$SCRIPT" --dir "$ROOT" --session "$SESSION" "$@"; }

# =============================================================================
# Structure
# =============================================================================

@test "check-diff-coverage: has correct shebang" {
    run head -1 "$SCRIPT"
    [ "$output" = "#!/usr/bin/env bash" ]
}

@test "check-diff-coverage: uses set -euo pipefail" {
    run grep -q 'set -euo pipefail' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "check-diff-coverage: requires --diff-lines" {
    run "$SCRIPT" --dir "$ROOT" --session "$SESSION"
    [ "$status" -ne 0 ]
}

@test "check-diff-coverage: errors when the session has no transcripts" {
    run "$SCRIPT" --dir "$ROOT" --session "no-such-session" --diff-lines 100
    [ "$status" -ne 0 ]
}

# =============================================================================
# Counting what the agent read
# =============================================================================

@test "check-diff-coverage: counts a single full Read as complete coverage" {
    make_agent code-reviewer-security a1 "$(read_block /tmp/diff.patch null null)"
    run_cov --diff-lines 500 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
    [ "$(echo "$output" | jq -r '.below_threshold | length')" -eq 0 ]
}

@test "check-diff-coverage: a default Read stops at 2000 lines" {
    # Read's default limit is what makes a long diff silently truncate.
    make_agent code-reviewer-security a1 "$(read_block /tmp/diff.patch null null)"
    run_cov --diff-lines 4000 --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 2000 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 50 ]
}

@test "check-diff-coverage: counts sed ranges run through Bash" {
    make_agent code-reviewer-testing a1 \
        "$(bash_block "sed -n '1,300p' /tmp/diff.patch")" \
        "$(bash_block "sed -n '301,600p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "sed" ]
}

@test "check-diff-coverage: counts Read and sed together" {
    make_agent code-reviewer-correctness a1 \
        "$(read_block /tmp/diff.patch 1 200)" \
        "$(bash_block "sed -n '201,400p' /tmp/diff.patch")"
    run_cov --diff-lines 400 --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "Read+sed" ]
}

@test "check-diff-coverage: overlapping ranges are not double counted" {
    make_agent code-reviewer-security a1 \
        "$(bash_block "sed -n '1,300p' /tmp/diff.patch")" \
        "$(bash_block "sed -n '200,400p' /tmp/diff.patch")"
    run_cov --diff-lines 800 --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 400 ]
}

@test "check-diff-coverage: reads past the diff end do not inflate coverage" {
    make_agent code-reviewer-security a1 "$(bash_block "sed -n '1,9999p' /tmp/diff.patch")"
    run_cov --diff-lines 500 --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 500 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: reports the ranges an agent never read" {
    make_agent code-reviewer-testing a1 "$(bash_block "sed -n '301,600p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents[0].unread_ranges[0][0]')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.agents[0].unread_ranges[0][1]')" -eq 300 ]
}

@test "check-diff-coverage: an agent that read nothing reports zero" {
    make_agent code-reviewer-security a1 "$(bash_block "grep -n foo /tmp/other.txt")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "none" ]
}

# =============================================================================
# Threshold and scope
# =============================================================================

@test "check-diff-coverage: flags agents under --min-pct" {
    make_agent code-reviewer-security full "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    make_agent code-reviewer-testing short "$(bash_block "sed -n '1,300p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --min-pct 90 --json
    [ "$(echo "$output" | jq -r '.below_threshold | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.below_threshold[0].agent')" = "code-reviewer-testing" ]
}

@test "check-diff-coverage: --min-pct 0 flags nobody" {
    make_agent code-reviewer-testing short "$(bash_block "sed -n '1,60p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --min-pct 0 --json
    [ "$(echo "$output" | jq -r '.below_threshold | length')" -eq 0 ]
}

@test "check-diff-coverage: ignores non-reviewer subagents" {
    make_agent code-review-context-explorer explorer "$(bash_block "sed -n '1,10p' /tmp/diff.patch")"
    make_agent code-reviewer-security rev "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.agents[0].agent')" = "code-reviewer-security" ]
}

@test "check-diff-coverage: skips transcripts with no meta file" {
    make_agent code-reviewer-security rev "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    : > "$SUBS/orphan.jsonl"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents | length')" -eq 1 ]
}

@test "check-diff-coverage: survives a malformed transcript line" {
    make_agent code-reviewer-security rev "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    echo 'not json at all' >> "$SUBS/rev.jsonl"
    run_cov --diff-lines 600 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: session defaults to CLAUDE_CODE_SESSION_ID" {
    make_agent code-reviewer-security rev "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    CLAUDE_CODE_SESSION_ID="$SESSION" run "$SCRIPT" --dir "$ROOT" --diff-lines 600 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

# =============================================================================
# Table output
# =============================================================================

@test "check-diff-coverage: table names the agents below threshold" {
    make_agent code-reviewer-testing short "$(bash_block "sed -n '1,60p' /tmp/diff.patch")"
    run_cov --diff-lines 600
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "code-reviewer-testing"
    echo "$output" | grep -q "Below 90%"
}

@test "check-diff-coverage: table says so when everyone read enough" {
    make_agent code-reviewer-security full "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    run_cov --diff-lines 600
    echo "$output" | grep -q "Every agent read at least"
}

# =============================================================================
# Chunked reviews: size each agent against the patch it actually read
# =============================================================================
#
# A chunked review hands each chunk's agents a different patch file with a
# different length. Sizing every agent against one --diff-lines count breaks in
# both directions: the larger count makes complete short-chunk agents look
# short (false alarms), and the smaller count lets a truncated long-chunk read
# wrap past 100% (a false clean). These tests pin that each agent is measured
# against the file it read.

# Write a real patch file of N lines into the tmpdir; print its path.
make_patch() { # $1 name, $2 lines
    local f="$BATS_TEST_TMPDIR/$1"
    seq "$2" | sed 's/^/+line /' > "$f"
    printf '%s' "$f"
}

@test "check-diff-coverage: sizes each same-type agent against its own chunk" {
    local chunk0="$(make_patch chunk-0.patch 2029)"
    local chunk1="$(make_patch chunk-1.patch 896)"
    make_agent code-reviewer-security a1 "$(bash_block "sed -n '1,2029p' $chunk0")"
    make_agent code-reviewer-security a2 "$(bash_block "sed -n '1,896p' $chunk1")"
    # --diff-lines carries chunk-0's count: the wrong denominator for a2.
    run_cov --diff-lines 2029 --json
    [ "$status" -eq 0 ]
    # Both are complete reads of their own chunk; neither is below threshold.
    [ "$(echo "$output" | jq '[.agents[] | .pct] | unique | .[0]')" -eq 100 ]
    [ "$(echo "$output" | jq '.below_threshold | length')" -eq 0 ]
    # The two same-type agents are distinguishable by the patch they read.
    [ "$(echo "$output" | jq -r '[.agents[] | .diff_path] | unique | length')" -eq 2 ]
}

@test "check-diff-coverage: a truncated long-chunk read is not a false clean" {
    # Regression for the dangerous direction: passing the smaller chunk's count
    # as the denominator lets 900/2029 compute as 900/896 and read as covered.
    local chunk0="$(make_patch chunk-0.patch 2029)"
    make_agent code-reviewer-correctness a1 "$(bash_block "sed -n '1,900p' $chunk0")"
    run_cov --diff-lines 896 --min-pct 90 --json
    [ "$status" -eq 0 ]
    # Sized against chunk-0 (2029 lines), 900 read is 44%, not 100%.
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 44 ]
    [ "$(echo "$output" | jq '.below_threshold | length')" -eq 1 ]
}

@test "check-diff-coverage: a stop-early agent on a long chunk is still caught" {
    local chunk0="$(make_patch chunk-0.patch 2029)"
    local chunk1="$(make_patch chunk-1.patch 896)"
    make_agent code-reviewer-security a1 "$(bash_block "sed -n '1,1250p' $chunk0")"
    make_agent code-reviewer-testing a2 "$(bash_block "sed -n '1,896p' $chunk1")"
    run_cov --diff-lines 2029 --min-pct 90 --json
    [ "$(echo "$output" | jq '.below_threshold | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.below_threshold[0].agent')" = "code-reviewer-security" ]
    [ "$(echo "$output" | jq -r '.below_threshold[0].pct')" -eq 62 ]
    # Re-dispatch feeds unread_ranges back to the agent; pin that the gap is
    # measured against the chunk's own 2029-line total, not the full diff's.
    [ "$(echo "$output" | jq -r '.below_threshold[0].unread_ranges[0] | join("-")')" = "1251-2029" ]
}

@test "check-diff-coverage: sizes a Read-truncated agent against its chunk" {
    local chunk1="$(make_patch chunk-1.patch 896)"
    make_agent code-reviewer-security a1 "$(read_block "$chunk1" null null)"
    # A default Read would report 2000 lines; the chunk is only 896. Sized
    # against the chunk itself, not the 2000-line default, this is complete.
    run_cov --diff-lines 2029 --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 896 ]
}

@test "check-diff-coverage: falls back to --diff-lines when the patch is gone" {
    # The patch file no longer exists on disk (e.g. the artifacts dir was
    # swept). The path is in the transcript but unreadable, so the script falls
    # back to --diff-lines rather than erroring.
    make_agent code-reviewer-security a1 "$(bash_block "sed -n '1,600p' /tmp/swept/diff.patch")"
    run_cov --diff-lines 600 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: a Read agent keeps its real chunk path" {
    local chunk0="$(make_patch chunk-0.patch 2029)"
    make_agent code-reviewer-frontend a1 "$(read_block "$chunk0" 1 2029)"
    run_cov --diff-lines 2029 --json
    [ "$(echo "$output" | jq -r '.agents[0].diff_path')" = "$chunk0" ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: an explicit-limit Read is clamped to the chunk length" {
    # A Read with offset 1 limit 2000 overshoots the 896-line chunk; the
    # min(b, total) clamp above bounds covered at the chunk's own lines. The
    # Read side of "reads past the diff end do not inflate coverage".
    local chunk1="$(make_patch chunk-1.patch 896)"
    make_agent code-reviewer-security a1 "$(read_block "$chunk1" 1 2000)"
    run_cov --diff-lines 2029 --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 896 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: a \$VAR path reports no coverage" {
    # A sed through a shell variable names no literal .patch, so the script
    # collects no interval for it at all — the read is invisible. That is the
    # conservative outcome: 0% coverage flags the agent for re-dispatch instead
    # of a false clean, rather than trusting a range it cannot place.
    make_agent code-reviewer-security a1 "$(bash_block "sed -n '1,900p' \"\$DIFF\"")"
    run_cov --diff-lines 2029 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].diff_path')" = "null" ]
    [ "$(echo "$output" | jq '.below_threshold | length')" -eq 1 ]
}

@test "check-diff-coverage: diff_path and total come from the same file when an agent names two patches" {
    # Regression for the independent-maxima bug: diff_path was the lexicographic
    # max of named paths and total the numeric max of their line counts, so the
    # row could name chunk-1 while sizing against chunk-0. They must pair up.
    local chunk0="$(make_patch chunk-0.patch 2029)"
    local chunk1="$(make_patch chunk-1.patch 896)"
    make_agent code-reviewer-security a1 \
        "$(bash_block "sed -n '1,2029p' $chunk0")" \
        "$(bash_block "sed -n '1,896p' $chunk1")"
    run_cov --diff-lines 2029 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].diff_path')" = "$chunk0" ]
    [ "$(echo "$output" | jq -r '.agents[0].total')" -eq 2029 ]
}

# =============================================================================
# Reads of the changed files in the checkout
# =============================================================================
#
# A reviewer can review a change by reading the changed files in the PR
# checkout instead of the patch. Those reads cover the new side of each hunk,
# so they count, but only when the file is under --repo-dir: in a cross-branch
# review the working tree holds different content, and the caller omits it.

# A patch that adds one 3-line file. Lines 1-6 are headers, 7-9 are content.
make_new_file_patch() {
    local f="$BATS_TEST_TMPDIR/new.patch"
    cat > "$f" <<'PATCH'
diff --git a/docs/a.md b/docs/a.md
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/docs/a.md
@@ -0,0 +1,3 @@
+alpha
+beta
+gamma
PATCH
    printf '%s' "$f"
}

# The new-file patch plus a modified file. Line 16 is the only removed line.
make_mixed_patch() {
    local f="$BATS_TEST_TMPDIR/mixed.patch"
    cat "$(make_new_file_patch)" > "$f"
    cat >> "$f" <<'PATCH'
diff --git a/src/b.py b/src/b.py
index 2222222..3333333 100644
--- a/src/b.py
+++ b/src/b.py
@@ -1,4 +1,4 @@
 one
-two
+TWO
 three
 four
PATCH
    printf '%s' "$f"
}

REPO() { printf '%s' "$BATS_TEST_TMPDIR/repo"; }

@test "check-diff-coverage: a full Read of a new file in the repo covers its patch section" {
    local patch="$(make_new_file_patch)"
    make_agent code-reviewer-correctness a1 "$(read_block "$(REPO)/docs/a.md" null null)"
    run_cov --diff-lines 9 --diff-file "$patch" --repo-dir "$(REPO)" --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "file" ]
    [ "$(echo "$output" | jq -r '.agents[0].diff_path')" = "$patch" ]
}

@test "check-diff-coverage: reading a modified file leaves its removed lines unread" {
    local patch="$(make_mixed_patch)"
    make_agent code-reviewer-maintainability a1 \
        "$(read_block "$(REPO)/docs/a.md" null null)" \
        "$(read_block "$(REPO)/src/b.py" null null)"
    run_cov --diff-lines 19 --diff-file "$patch" --repo-dir "$(REPO)" --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 18 ]
    [ "$(echo "$output" | jq -c '.agents[0].unread_ranges')" = "[[16,16]]" ]
}

@test "check-diff-coverage: a partial Read credits only the lines it returned" {
    local patch="$(make_new_file_patch)"
    make_agent code-reviewer-correctness a1 "$(read_block "$(REPO)/docs/a.md" 2 1)"
    run_cov --diff-lines 9 --diff-file "$patch" --repo-dir "$(REPO)" --json
    # The six header lines plus patch line 8, which holds new line 2.
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 7 ]
    [ "$(echo "$output" | jq -c '.agents[0].unread_ranges')" = "[[7,7],[9,9]]" ]
}

@test "check-diff-coverage: a sed range on a relative path after cd into the repo counts" {
    local patch="$(make_new_file_patch)"
    make_agent code-reviewer-testing a1 "$(bash_block "cd $(REPO) && sed -n '1,2p' docs/a.md")"
    run_cov --diff-lines 9 --diff-file "$patch" --repo-dir "$(REPO)" --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 8 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "file" ]
}

@test "check-diff-coverage: a Read outside --repo-dir is not credited" {
    local patch="$(make_new_file_patch)"
    make_agent code-reviewer-correctness a1 "$(read_block /elsewhere/docs/a.md null null)"
    run_cov --diff-lines 9 --diff-file "$patch" --repo-dir "$(REPO)" --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "none" ]
}

@test "check-diff-coverage: without --repo-dir file reads earn nothing" {
    local patch="$(make_new_file_patch)"
    make_agent code-reviewer-correctness a1 "$(read_block "$(REPO)/docs/a.md" null null)"
    run_cov --diff-lines 9 --diff-file "$patch" --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 0 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "none" ]
}

@test "check-diff-coverage: file reads map against the patch the agent named" {
    # The agent sized its own patch with wc and then read the files. With no
    # --diff-file, the named patch is the only map from files to patch lines.
    local patch="$(make_new_file_patch)"
    make_agent code-reviewer-maintainability a1 \
        "$(bash_block "wc -l $patch")" \
        "$(read_block "$(REPO)/docs/a.md" null null)"
    run_cov --diff-lines 9 --repo-dir "$(REPO)" --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: patch and file reads combine without double counting" {
    local patch="$(make_mixed_patch)"
    make_agent code-reviewer-security a1 \
        "$(bash_block "sed -n '1,12p' $patch")" \
        "$(read_block "$(REPO)/src/b.py" null null)"
    run_cov --diff-lines 19 --diff-file "$patch" --repo-dir "$(REPO)" --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 18 ]
    [ "$(echo "$output" | jq -r '.agents[0].method')" = "file+sed" ]
}

@test "check-diff-coverage: an unquoted sed range counts" {
    make_agent code-reviewer-testing a1 "$(bash_block "sed -n 1,600p /tmp/diff.patch")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: an agent that read nothing has the whole diff unread" {
    # The re-dispatch prompt sends these ranges back to the agent, so an empty
    # list would leave it nothing to read.
    make_agent code-reviewer-security a1 "$(bash_block "grep -n foo /tmp/other.txt")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -c '.agents[0].unread_ranges')" = "[[1,600]]" ]
}

@test "check-diff-coverage: the comment and voice agents are not reviewers" {
    make_agent code-reviewer-comment composer "$(bash_block "grep -n foo /tmp/other.txt")"
    make_agent code-reviewer-voice voice "$(bash_block "grep -n foo /tmp/other.txt")"
    make_agent code-reviewer-security rev "$(bash_block "sed -n '1,600p' /tmp/diff.patch")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '[.agents[].agent] | join(",")')" = "code-reviewer-security" ]
}

@test "check-diff-coverage: a sed of another file does not count toward the patch the command names" {
    make_agent code-reviewer-testing a1 "$(bash_block "wc -l /tmp/diff.patch; sed -n '1,300p' docs/a.md")"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -r '.agents[0].covered')" -eq 0 ]
}

@test "check-diff-coverage: a sed of the patch through a redirect, -- or a variable still counts" {
    make_agent code-reviewer-security a1 "$(bash_block "sed -n '1,600p' < /tmp/diff.patch")"
    make_agent code-reviewer-testing a2 "$(bash_block "sed -n '1,600p' -- /tmp/diff.patch")"
    make_agent code-reviewer-correctness a3 "$(bash_block 'P=/tmp/diff.patch; sed -n "1,600p" "$P"')"
    run_cov --diff-lines 600 --json
    [ "$(echo "$output" | jq -c '[.agents[].pct] | unique')" = "[100]" ]
}

@test "check-diff-coverage: files whose paths git pads with a tab or quotes still map" {
    local patch="$BATS_TEST_TMPDIR/odd.patch"
    printf '%s\n' \
        'diff --git a/my file.md b/my file.md' \
        'new file mode 100644' \
        '--- /dev/null' \
        $'+++ b/my file.md\t' \
        '@@ -0,0 +1 @@' \
        '+spaced' \
        'diff --git "a/r\303\251sum\303\251.md" "b/r\303\251sum\303\251.md"' \
        'new file mode 100644' \
        '--- /dev/null' \
        '+++ "b/r\303\251sum\303\251.md"' \
        '@@ -0,0 +1 @@' \
        '+accented' > "$patch"
    make_agent code-reviewer-correctness a1 \
        "$(read_block "$(REPO)/my file.md" null null)" \
        "$(read_block "$(REPO)/résumé.md" null null)"
    run_cov --diff-lines 12 --diff-file "$patch" --repo-dir "$(REPO)" --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: a carriage return inside a line does not shift later files" {
    local patch="$BATS_TEST_TMPDIR/cr.patch"
    printf 'diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -1 +1 @@\n-old\r text\n+new\ndiff --git a/b.md b/b.md\n--- a/b.md\n+++ b/b.md\n@@ -1 +1 @@\n-gone\n+kept\n' > "$patch"
    make_agent code-reviewer-correctness a1 "$(read_block "$(REPO)/b.md" null null)"
    run_cov --diff-lines 12 --diff-file "$patch" --repo-dir "$(REPO)" --json
    # b.md's headers are lines 7-10 and its added line is 12; line 11 is removed.
    [ "$(echo "$output" | jq -c '.agents[0].unread_ranges')" = "[[1,6],[11,11]]" ]
}

@test "check-diff-coverage: a cd on its own line or in a subshell counts" {
    local patch="$(make_new_file_patch)"
    make_agent code-reviewer-testing a1 "$(bash_block "cd $(REPO)
sed -n '1,1p' docs/a.md")"
    make_agent code-reviewer-security a2 "$(bash_block "(cd $(REPO) && sed -n '2,3p' docs/a.md)")"
    run_cov --diff-lines 9 --diff-file "$patch" --repo-dir "$(REPO)" --json
    [ "$(echo "$output" | jq -r '.agents[] | select(.agent == "code-reviewer-testing") | .covered')" -eq 7 ]
    [ "$(echo "$output" | jq -r '.agents[] | select(.agent == "code-reviewer-security") | .covered')" -eq 8 ]
}

@test "check-diff-coverage: a file with two sections in one diff credits both" {
    # Local reviews can join the staged and unstaged diffs, which repeats a file.
    local patch="$BATS_TEST_TMPDIR/twice.patch"
    cat "$(make_new_file_patch)" "$(make_new_file_patch)" > "$patch"
    make_agent code-reviewer-correctness a1 "$(read_block "$(REPO)/docs/a.md" null null)"
    run_cov --diff-lines 18 --diff-file "$patch" --repo-dir "$(REPO)" --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}

@test "check-diff-coverage: a Read through a symlink to --repo-dir counts" {
    local patch="$(make_new_file_patch)"
    mkdir -p "$(REPO)/docs" && : > "$(REPO)/docs/a.md"
    ln -s "$(REPO)" "$BATS_TEST_TMPDIR/link"
    make_agent code-reviewer-correctness a1 "$(read_block "$BATS_TEST_TMPDIR/link/docs/a.md" null null)"
    run_cov --diff-lines 9 --diff-file "$patch" --repo-dir "$(REPO)" --json
    [ "$(echo "$output" | jq -r '.agents[0].pct')" -eq 100 ]
}
