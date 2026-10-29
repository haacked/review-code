#!/usr/bin/env bats
# Flags that let a caller such as /go scale a review: --reviewers,
# --max-fraction, and the comment_gates decision for --fix. A PR URL needs no
# git repository or network, which is what lets a caller probe the installed
# copy for support.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    PARSE="$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
    PR_URL="https://github.com/org/repo/pull/42"
    cd "$BATS_TEST_TMPDIR"
}

@test "comment gates: --fix without --draft skips them" {
    run "$PARSE" "$PR_URL" --fix --force
    [ "$status" -eq 0 ]
    jq -e '.comment_gates == "skip"' <<< "$output"
}

@test "comment gates: --fix with --draft keeps them" {
    run "$PARSE" "$PR_URL" --fix --draft
    [ "$status" -eq 0 ]
    jq -e '.comment_gates == "run"' <<< "$output"
}

@test "comment gates: a review without --fix keeps them" {
    run "$PARSE" "$PR_URL" --force
    [ "$status" -eq 0 ]
    jq -e '.comment_gates == "run"' <<< "$output"
}

@test "reviewers: a PR URL review records the list with correctness first and no duplicates" {
    run "$PARSE" "$PR_URL" --reviewers testing,security,testing
    [ "$status" -eq 0 ]
    jq -e '.mode == "pr" and .reviewers == "correctness,testing,security"' <<< "$output"
}

@test "reviewers: the equals form and a correctness-only list both parse" {
    run "$PARSE" "$PR_URL" --reviewers=correctness
    [ "$status" -eq 0 ]
    jq -e '.reviewers == "correctness"' <<< "$output"
}

@test "reviewers: an omitted flag leaves no reviewers field" {
    run "$PARSE" "$PR_URL"
    [ "$status" -eq 0 ]
    jq -e 'has("reviewers") | not' <<< "$output"
}

@test "reviewers: an unknown area fails and names the valid areas" {
    run "$PARSE" "$PR_URL" --reviewers correctness,bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown area in --reviewers: 'bogus'"* ]]
    [[ "$output" == *"infra-config"* ]]
}

@test "reviewers: a missing or empty list fails" {
    for args in "--reviewers" "--reviewers ," "--reviewers="; do
        # shellcheck disable=SC2086
        run "$PARSE" "$PR_URL" $args
        [ "$status" -eq 1 ]
        [[ "$output" == *"--reviewers requires a comma-separated list"* ]]
    done
}

@test "reviewers: cannot be combined with an area argument" {
    run "$PARSE" security --reviewers testing
    [ "$status" -eq 1 ]
    [[ "$output" == *"either an area argument or --reviewers"* ]]
}

@test "reviewers and max-fraction: rejected in find and learn modes" {
    run "$PARSE" find 42 --reviewers testing
    [ "$status" -eq 1 ]
    [[ "$output" == *"--reviewers is not compatible with find mode"* ]]

    run "$PARSE" learn 42 --max-fraction 0.8
    [ "$status" -eq 1 ]
    [[ "$output" == *"--max-fraction is not compatible with learn mode"* ]]
}

@test "max-fraction: a value in range is recorded" {
    for value in 0.8 1 .25 1.0; do
        run "$PARSE" "$PR_URL" --append --max-fraction "$value"
        [ "$status" -eq 0 ]
        jq -e --arg value "$value" '.max_fraction == $value' <<< "$output"
    done
}

@test "max-fraction: a value out of range, not a number, or missing fails" {
    for value in 0 1.5 abc -0.5 0.5.1; do
        run "$PARSE" "$PR_URL" --append --max-fraction "$value"
        [ "$status" -eq 1 ]
        [[ "$output" == *"--max-fraction requires a number greater than 0 and at most 1"* ]]
    done
    run "$PARSE" "$PR_URL" --append --max-fraction
    [ "$status" -eq 1 ]
    [[ "$output" == *"--max-fraction requires a number"* ]]
}

@test "max-fraction: fails without --append instead of being ignored" {
    run "$PARSE" "$PR_URL" --max-fraction 0.8
    [ "$status" -eq 1 ]
    [[ "$output" == *"--max-fraction only applies to an --append re-review"* ]]
}

@test "PR mode: an area left out of the --reviewers list is suggested as an addition" {
    run "$PARSE" "$PR_URL" --reviewers testing security
    [ "$status" -eq 1 ]
    [[ "$output" == *"Add 'security' to the --reviewers list"* ]]
}

@test "PR mode: an area after a PR URL fails and names --reviewers" {
    run "$PARSE" "$PR_URL" correctness
    [ "$status" -eq 1 ]
    [[ "$output" == *"--reviewers correctness"* ]]
}

@test "PR mode: a file pattern after a PR number fails instead of being ignored" {
    run "$PARSE" 123 "src/**/*.ts"
    [ "$status" -eq 1 ]
    [[ "$output" == *"do not take a file pattern"* ]]
    [[ "$output" == *"--reviewers"* ]]
}

@test "area mode: a PR after an area fails and names --reviewers" {
    for pr in "$PR_URL" 123; do
        run "$PARSE" security "$pr"
        [ "$status" -eq 1 ]
        [[ "$output" == *"--reviewers security"* ]]
    done
}

@test "find mode: a PR with a second argument still parses" {
    run "$PARSE" find 123 extra
    [ "$status" -eq 0 ]
    jq -e '.find_mode == "true" and .pr_number == "123"' <<< "$output"
}

@test "a pending --parent check does not claim another flag's missing value" {
    run "$PARSE" "$PR_URL" --reviewers
    [[ "$output" != *"--parent"* ]]
    run "$PARSE" --parent
    [ "$status" -eq 1 ]
    [[ "$output" == *"--parent requires a value"* ]]
}
