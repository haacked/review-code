#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/domain-review.py"
    export REVIEW_CODE_DOMAIN_DIR="$BATS_TEST_TMPDIR/domains"
    export REVIEW_CODE_DOMAIN_CACHE="$BATS_TEST_TMPDIR/slots"
    export REVIEW_CODE_WORKTREE_DIR="$BATS_TEST_TMPDIR/worktrees"
    mkdir -p "$REVIEW_CODE_DOMAIN_DIR" "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    write_domain 60
    write_codex_stub
    make_repo
}

write_domain() {
    cat > "$REVIEW_CODE_DOMAIN_DIR/sql.md" << EOF
---
# A comment line is ignored.
repos: acme/app
paths: app/sql/*
content_files: *.py
content: compile_query
timeout: $1
links: .venv
slots: s1 s2
env: TEST_SLOT={SLOT}
---
Review {DIFF_PATH} in slot {SLOT}.
EOF
}

# The stub records what Codex would see, then answers in the report shape.
write_codex_stub() {
    cat > "$BATS_TEST_TMPDIR/bin/codex" << 'EOF'
#!/usr/bin/env bash
out="" dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -C) dir="$2"; shift ;;
    esac
    shift
done
record="$(dirname "$out")/stub-record"
{
    echo "pid=$$"
    echo "slot=${TEST_SLOT:-}"
    echo "file=$(cat "$dir/app/sql/query.py")"
    [[ -f "$dir/app/sql/new.py" ]] && echo "untracked=$(cat "$dir/app/sql/new.py")"
    [[ -L "$dir/.venv" ]] && echo "venv=linked"
    cat
} > "$record"
mkdir -p "$dir/.codex-scratch"
echo "repro" > "$dir/.codex-scratch/test_repro.py"
[[ -n "${STUB_SLEEP:-}" ]] && sleep "$STUB_SLEEP"
[[ -n "${STUB_EXIT:-}" ]] && exit "$STUB_EXIT"
printf '%s' '{"investigation":"Compiled two queries.","findings":"","coverage":{"files_read":["app/sql/query.py"],"gaps":[]}}' > "$out"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/codex"
}

make_repo() {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/app/sql" "$REPO/.venv"
    git -C "$REPO" init -q -b main
    echo "old" > "$REPO/app/sql/query.py"
    printf '.venv\n' > "$REPO/.gitignore"
    git -C "$REPO" add -A
    git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -qm base
    git -C "$REPO" checkout -qb feature
    echo "new" > "$REPO/app/sql/query.py"
    git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -qam change
    ARTIFACTS="$BATS_TEST_TMPDIR/artifacts dir"
    mkdir -p "$ARTIFACTS"
    git -C "$REPO" diff main feature > "$ARTIFACTS/diff.patch"
}

write_session() {
    SESSION="$ARTIFACTS/session.json"
    jq -n --arg repo "${2:-$REPO}" --arg artifacts "$ARTIFACTS" --arg mode "$1" '{
        mode: $mode,
        branch: "feature",
        git: {org: "acme", repo: "app", branch: "feature", working_dir: $repo, local_clone: null},
        artifacts_dir: $artifacts,
        diff_path: ($artifacts + "/diff.patch")
    }' > "$SESSION"
}

start_review() {
    run python3 "$SCRIPT" start --session-file "$SESSION" --name sql
    [ "$status" -eq 0 ]
    STATE=$(jq -r .state_path <<< "$output")
    WORKTREE=$(jq -r .worktree <<< "$output")
}

wait_review() {
    run python3 "$SCRIPT" wait --state "$STATE" --max-seconds 60
    [ "$status" -eq 0 ]
}

plan_for() {
    printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/plan.patch"
    run python3 "$SCRIPT" plan --org "${3:-Acme}" --repo app --diff-file "$BATS_TEST_TMPDIR/plan.patch"
    [ "$status" -eq 0 ]
    PLAN="$output"
}

@test "plan matches a changed path against the domain's globs" {
    plan_for path $'diff --git a/app/sql/q.py b/app/sql/q.py\n--- a/app/sql/q.py\n+++ b/app/sql/q.py\n@@ -1 +1 @@\n-a\n+b'
    jq -e 'length == 1 and .[0].name == "sql" and (.[0].reason | contains("app/sql/*"))' <<< "$PLAN"
}

@test "plan matches changed content only in the domain's content files" {
    plan_for content $'diff --git a/lib/x.py b/lib/x.py\n--- a/lib/x.py\n+++ b/lib/x.py\n@@ -1 +1 @@\n-a\n+compile_query(q)'
    jq -e 'length == 1 and (.[0].reason | contains("lib/x.py"))' <<< "$PLAN"
    plan_for content $'diff --git a/web/x.ts b/web/x.ts\n--- a/web/x.ts\n+++ b/web/x.ts\n@@ -1 +1 @@\n-a\n+compile_query(q)'
    [ "$PLAN" = "[]" ]
}

@test "plan skips other repositories and an unchanged context line" {
    plan_for repo $'diff --git a/app/sql/q.py b/app/sql/q.py\n--- a/app/sql/q.py\n+++ b/app/sql/q.py\n@@ -1 +1 @@\n-a\n+b' other
    [ "$PLAN" = "[]" ]
    plan_for context $'diff --git a/lib/x.py b/lib/x.py\n--- a/lib/x.py\n+++ b/lib/x.py\n@@ -1,2 +1,2 @@\n compile_query(q)\n-a\n+b'
    [ "$PLAN" = "[]" ]
}

@test "plan reads a removed line that starts with dashes as content, not a file header" {
    plan_for dashes $'diff --git a/lib/q.py b/lib/q.py\n--- a/lib/q.py\n+++ b/lib/q.py\n@@ -1,2 +1,2 @@\n--- old comment\n-a\n+compile_query(q)'
    jq -e 'length == 1 and (.[0].reason | contains("lib/q.py"))' <<< "$PLAN"
}

@test "plan skips a malformed domain file and still runs the others" {
    printf 'no frontmatter\n' > "$REVIEW_CODE_DOMAIN_DIR/broken.md"
    printf -- '---\r\nrepos: acme/app\r\npaths: lib/*\r\n---\r\nprompt\r\n' > "$REVIEW_CODE_DOMAIN_DIR/crlf.md"
    printf 'diff --git a/lib/x.py b/lib/x.py\n--- a/lib/x.py\n+++ b/lib/x.py\n@@ -1 +1 @@\n-a\n+b\n' > "$BATS_TEST_TMPDIR/plan.patch"
    run --separate-stderr python3 "$SCRIPT" plan --org acme --repo app --diff-file "$BATS_TEST_TMPDIR/plan.patch"
    [ "$status" -eq 0 ]
    jq -e '[.[].name] == ["crlf"]' <<< "$output"
    [[ "$stderr" == *"skipping broken.md"* ]]
}

@test "plan returns nothing when domain reviews are turned off" {
    REVIEW_CODE_DOMAIN_REVIEWS=0 plan_for off $'diff --git a/app/sql/q.py b/app/sql/q.py\n--- a/app/sql/q.py\n+++ b/app/sql/q.py\n@@ -1 +1 @@\n-a\n+b'
    [ "$PLAN" = "[]" ]
}

@test "a branch review runs Codex on the branch head and writes a reviewer report" {
    write_session branch
    start_review
    wait_review
    jq -e '.status == "done" and .report_name == "domain-sql"' <<< "$output"
    report=$(jq -r .report_path <<< "$output")
    jq -e '.open_from_others == [] and .coverage.files_read == ["app/sql/query.py"]' "$report"
    python3 "$PROJECT_ROOT/skills/review-code/scripts/reviewer-report.py" --input "$report" --output-dir "$ARTIFACTS" --name domain-sql
    record="$ARTIFACTS/domain-reviews/sql/stub-record"
    grep -qx 'slot=s1' "$record"
    grep -qx 'file=new' "$record"
    grep -qx 'venv=linked' "$record"
    diff_real="$(cd "$ARTIFACTS" && pwd -P)/diff.patch"
    grep -qF "Review $diff_real in slot s1." "$record"
    [ ! -e "$WORKTREE" ]
    [ ! -e "$REVIEW_CODE_DOMAIN_CACHE/sql/s1" ]
    [ "$(git -C "$REPO" worktree list | wc -l)" -eq 1 ]
}

@test "a local review copies uncommitted and untracked work into the scratch checkout" {
    git -C "$REPO" checkout -q main
    echo "uncommitted" > "$REPO/app/sql/query.py"
    echo "brand new" > "$REPO/app/sql/new.py"
    write_session local
    start_review
    wait_review
    jq -e '.status == "done"' <<< "$output"
    grep -qx 'file=uncommitted' "$ARTIFACTS/domain-reviews/sql/stub-record"
    grep -qx 'untracked=brand new' "$ARTIFACTS/domain-reviews/sql/stub-record"
    [ "$(cat "$REPO/app/sql/query.py")" = "uncommitted" ]
}

@test "a local review with no uncommitted work checks out HEAD as it is" {
    write_session local
    start_review
    wait_review
    jq -e '.status == "done"' <<< "$output"
    grep -qx 'file=new' "$ARTIFACTS/domain-reviews/sql/stub-record"
}

@test "a branch review checks out the branch under review, not the branch in the shell" {
    git -C "$REPO" checkout -q main
    write_session branch
    jq '.git.branch = "main"' "$SESSION" > "$SESSION.tmp" && mv "$SESSION.tmp" "$SESSION"
    start_review
    wait_review
    grep -qx 'file=new' "$ARTIFACTS/domain-reviews/sql/stub-record"
}

@test "links resolve from the repository root when the review runs in a subdirectory" {
    write_session branch "$REPO/app/sql"
    start_review
    wait_review
    grep -qx 'venv=linked' "$ARTIFACTS/domain-reviews/sql/stub-record"
}

@test "the reproduction files survive the scratch checkout" {
    write_session branch
    start_review
    wait_review
    [ "$(cat "$ARTIFACTS/domain-reviews/sql/scratch/test_repro.py")" = "repro" ]
    [ ! -e "$WORKTREE" ]
}

@test "cleanup stops Codex and its runner before releasing the slot" {
    write_session branch
    STUB_SLEEP=60 start_review
    for _ in $(seq 50); do [[ -s "$ARTIFACTS/domain-reviews/sql/stub-record" ]] && break; sleep 0.1; done
    stub_pid=$(sed -n 's/^pid=//p' "$ARTIFACTS/domain-reviews/sql/stub-record")
    [ -n "$stub_pid" ]
    run python3 "$SCRIPT" cleanup --state "$STATE"
    [ "$status" -eq 0 ]
    ! kill -0 "$stub_pid" 2> /dev/null
    [ ! -e "$WORKTREE" ]
    [ ! -e "$REVIEW_CODE_DOMAIN_CACHE/sql/s1" ]
    jq -e '.status == "failed"' "$ARTIFACTS/domain-reviews/sql/status.json"
}

@test "wait fails a run whose state never recorded a runner" {
    write_session branch
    STUB_SLEEP=60 start_review
    python3 "$SCRIPT" cleanup --state "$STATE" > /dev/null
    jq 'del(.runner_pid)' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    jq '.status = "running"' "$ARTIFACTS/domain-reviews/sql/status.json" > "$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$ARTIFACTS/domain-reviews/sql/status.json"
    run python3 "$SCRIPT" wait --state "$STATE" --max-seconds 5
    [ "$status" -eq 0 ]
    jq -e '.status == "failed"' <<< "$output"
}

@test "the runner records its own pid in the slot lock" {
    write_session branch
    STUB_SLEEP=60 start_review
    for _ in $(seq 50); do [[ -s "$REVIEW_CODE_DOMAIN_CACHE/sql/s1/pid" ]] && break; sleep 0.1; done
    [ "$(cat "$REVIEW_CODE_DOMAIN_CACHE/sql/s1/pid")" = "$(jq -r .runner_pid "$STATE")" ]
    python3 "$SCRIPT" cleanup --state "$STATE" > /dev/null
}

@test "a run past the timeout is stopped and its checkout removed" {
    write_domain 1
    write_session branch
    STUB_SLEEP=30 start_review
    wait_review
    jq -e '.status == "timed_out"' <<< "$output"
    [ ! -e "$WORKTREE" ]
    [ ! -e "$REVIEW_CODE_DOMAIN_CACHE/sql/s1" ]
}

@test "a Codex failure is reported without a report file" {
    write_session branch
    STUB_EXIT=3 start_review
    wait_review
    jq -e '.status == "failed" and (.error | contains("exited 3"))' <<< "$output"
    [ ! -e "$(jq -r .report_path <<< "$output")" ]
    [ ! -e "$WORKTREE" ]
}

@test "start refuses when every slot is held by a live process and leaves no checkout" {
    mkdir -p "$REVIEW_CODE_DOMAIN_CACHE/sql/s1" "$REVIEW_CODE_DOMAIN_CACHE/sql/s2"
    echo $$ > "$REVIEW_CODE_DOMAIN_CACHE/sql/s1/pid"
    echo $$ > "$REVIEW_CODE_DOMAIN_CACHE/sql/s2/pid"
    write_session branch
    run python3 "$SCRIPT" start --session-file "$SESSION" --name sql
    [ "$status" -ne 0 ]
    [[ "$output" == *"every slot for sql is in use"* ]]
    [ "$(git -C "$REPO" worktree list | wc -l)" -eq 1 ]
}

@test "a slot held by a live pid past the maximum lock age is reclaimed" {
    mkdir -p "$REVIEW_CODE_DOMAIN_CACHE/sql/s1"
    echo $$ > "$REVIEW_CODE_DOMAIN_CACHE/sql/s1/pid"
    touch -t 202001010000 "$REVIEW_CODE_DOMAIN_CACHE/sql/s1"
    write_session branch
    start_review
    wait_review
    grep -qx 'slot=s1' "$ARTIFACTS/domain-reviews/sql/stub-record"
}

@test "a start that fails leaves no state, so a retry can start" {
    write_session branch
    jq '.git.branch = "missing" | .branch = "missing"' "$SESSION" > "$SESSION.tmp" && mv "$SESSION.tmp" "$SESSION"
    run python3 "$SCRIPT" start --session-file "$SESSION" --name sql
    [ "$status" -ne 0 ]
    write_session branch
    start_review
    wait_review
    jq -e '.status == "done"' <<< "$output"
}

@test "a slot whose owner has exited is reclaimed" {
    mkdir -p "$REVIEW_CODE_DOMAIN_CACHE/sql/s1"
    echo 999999 > "$REVIEW_CODE_DOMAIN_CACHE/sql/s1/pid"
    write_session branch
    start_review
    wait_review
    grep -qx 'slot=s1' "$ARTIFACTS/domain-reviews/sql/stub-record"
}
