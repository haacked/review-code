#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPTS="$PROJECT_ROOT/skills/review-code/scripts"
    TEST_TEMP_DIR="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME"
    unset REVIEW_CODE_REVIEW_DIR
    source "$SCRIPTS/helpers/config-helpers.sh"
}

@test "review root override accepts an absolute path containing spaces" {
    export REVIEW_CODE_REVIEW_DIR="$TEST_TEMP_DIR/isolated attempt/review reports"

    run get_review_root

    [ "$status" -eq 0 ]
    [ "$output" = "$REVIEW_CODE_REVIEW_DIR" ]
}

@test "review path lookup and token logs use the overridden root" {
    export REVIEW_CODE_REVIEW_DIR="$TEST_TEMP_DIR/isolated attempt/review reports"
    local global_root="$HOME/.agents/skills/review-code/.reviews"
    mkdir -p "$global_root/org/repo" "$REVIEW_CODE_REVIEW_DIR/org/repo"
    echo 'Global review history' > "$global_root/org/repo/pr-123.md"
    echo 'Global token history' > "$global_root/token-usage.jsonl"
    echo 'Isolated review' > "$REVIEW_CODE_REVIEW_DIR/org/repo/pr-123.md"

    run "$SCRIPTS/review-file-path.sh" --org org --repo repo 123

    [ "$status" -eq 0 ]
    local review_file
    review_file=$(echo "$output" | jq -r '.file_path')
    [ "$review_file" = "$REVIEW_CODE_REVIEW_DIR/org/repo/pr-123.md" ]
    echo "$output" | jq -e '.file_exists == true'

    run "$SCRIPTS/log-token-usage.sh" --review-file "$review_file" \
        --usage '{"code-reviewer-security": 1234}' --org org --repo repo --mode pr --identifier 123

    [ "$status" -eq 0 ]
    [ "$output" = "$REVIEW_CODE_REVIEW_DIR/token-usage.jsonl" ]
    jq -e '.total_tokens == 1234 and .identifier == "123"' "$output"
    [ "$(cat "$global_root/org/repo/pr-123.md")" = 'Global review history' ]
    [ "$(cat "$global_root/token-usage.jsonl")" = 'Global token history' ]
}

@test "review root defaults to canonical storage when override is absent" {
    local expected="$HOME/.agents/skills/review-code/.reviews"
    mkdir -p "$expected"

    run get_review_root
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]

    run "$SCRIPTS/review-file-path.sh" --org org --repo repo 123
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.file_path')" = "$expected/org/repo/pr-123.md" ]
}

@test "review root defaults to canonical storage when override is empty" {
    export REVIEW_CODE_REVIEW_DIR=""
    local expected="$HOME/.agents/skills/review-code/.reviews"
    mkdir -p "$expected"

    run get_review_root
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]

    run "$SCRIPTS/review-file-path.sh" --org org --repo repo 123
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.file_path')" = "$expected/org/repo/pr-123.md" ]
}

@test "review root retains legacy fallback without a nonempty override" {
    local expected="$HOME/.claude/skills/review-code/.reviews"
    mkdir -p "$expected"

    run get_review_root
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]

    export REVIEW_CODE_REVIEW_DIR=""
    run get_review_root
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}
