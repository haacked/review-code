#!/usr/bin/env bats
# run-eval.sh drives real `claude -p` reviews. A stub claude on PATH writes the
# review where the skill would, so these tests check the harness's file handling
# without paying for a review.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/home"
    USER_REVIEW="$HOME/.agents/skills/review-code/.reviews/posthog/posthog/pr-116693.md"
    mkdir -p "$(dirname "$USER_REVIEW")" "$TEST_TMP/bin"
    echo "the user's own review" > "$USER_REVIEW"

    # The fallbacks are the skill's own defaults, so a harness that sets no
    # roots sends the stub's writes into the user's install.
    cat > "$TEST_TMP/bin/claude" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "stub"
    exit 0
fi
env > "${STUB_ENV_LOG}"
reviews="${REVIEW_CODE_REVIEW_DIR:-${HOME}/.agents/skills/review-code/.reviews}"
mkdir -p "${reviews}/posthog/posthog"
echo "stub review" > "${reviews}/posthog/posthog/pr-116693.md"
if [[ -n "${STUB_LEAVE_WORKTREE:-}" ]]; then
    mkdir -p "${REVIEW_CODE_WORKTREE_DIR:-${HOME}/.agents/skills/review-code/.worktrees}/posthog/posthog/pr-116693"
fi
EOF
    chmod +x "$TEST_TMP/bin/claude"
    export PATH="$TEST_TMP/bin:$PATH"
    export STUB_ENV_LOG="$TEST_TMP/env.log"
}

teardown() {
    [[ -z "${RUN_ID:-}" ]] || rm -rf "$PROJECT_ROOT/evals/results/$RUN_ID"
    rm -rf "$TEST_TMP"
}

run_pr_benchmark_eval() {
    run "$PROJECT_ROOT/evals/scripts/run-eval.sh" --benchmark hogql-group-prefilter-joined-where --approach skill
    RUN_ID=$(sed -n 's/^Starting eval run: \([^ ]*\).*/\1/p' <<< "$output")
    RESULT_DIR="$PROJECT_ROOT/evals/results/$RUN_ID/hogql-group-prefilter-joined-where"
}

@test "run-eval: a PR benchmark leaves the user's review of the PR alone" {
    run_pr_benchmark_eval
    [ "$status" -eq 0 ]
    [ -n "$RUN_ID" ]

    [ "$(cat "$USER_REVIEW")" = "the user's own review" ]
    [ "$(cat "$RESULT_DIR/review.md")" = "stub review" ]
}

@test "run-eval: a PR benchmark keeps review, session, and worktree state under its result directory" {
    run_pr_benchmark_eval
    [ "$status" -eq 0 ]

    grep -qxF "REVIEW_CODE_REVIEW_DIR=$RESULT_DIR/state/reviews" "$STUB_ENV_LOG"
    grep -qxF "CLAUDE_SESSION_DIR=$RESULT_DIR/state/sessions" "$STUB_ENV_LOG"
    grep -qxF "REVIEW_CODE_WORKTREE_DIR=$RESULT_DIR/state/worktrees" "$STUB_ENV_LOG"
}

@test "run-eval: a PR benchmark with a pr-body.md reviews against that description" {
    run_pr_benchmark_eval
    [ "$status" -eq 0 ]

    grep -qxF "REVIEW_CODE_FROZEN_PR_BODY=$PROJECT_ROOT/evals/benchmarks/posthog/hogql-group-prefilter-joined-where/pr-body.md" "$STUB_ENV_LOG"
}

@test "run-eval: a PR benchmark warns about a worktree the review left behind" {
    export STUB_LEAVE_WORKTREE=1
    run_pr_benchmark_eval
    [ "$status" -eq 0 ]

    [[ "$output" == *"review left a worktree at $RESULT_DIR/state/worktrees/posthog/posthog/pr-116693"* ]]
}
