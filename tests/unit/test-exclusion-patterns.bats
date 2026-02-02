#!/usr/bin/env bats
# Unit tests for exclusion-patterns.sh

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/skills/review-code/scripts/helpers/exclusion-patterns.sh"
}

@test "exclusion-patterns.sh exists and is executable" {
    [ -f "$SCRIPT" ]
}

@test "can source the helper script" {
    source "$SCRIPT"
    type get_exclusion_patterns | grep -q "function"
}

@test "common mode excludes lock files" {
    source "$SCRIPT"
    result=$(get_exclusion_patterns common)

    echo "$result" | grep -q ":!package-lock.json"
    echo "$result" | grep -q ":!pnpm-lock.yaml"
    echo "$result" | grep -q ":!yarn.lock"
    echo "$result" | grep -q ":!Cargo.lock"
}

@test "common mode excludes minified files" {
    source "$SCRIPT"
    result=$(get_exclusion_patterns common)

    echo "$result" | grep -q ":!\*.min.js"
    echo "$result" | grep -q ":!\*.min.css"
}

@test "common mode excludes build outputs" {
    source "$SCRIPT"
    result=$(get_exclusion_patterns common)

    echo "$result" | grep -q ":!dist/"
    echo "$result" | grep -q ":!build/"
    echo "$result" | grep -q ":!.generated/"
}

@test "extended mode includes all common patterns" {
    source "$SCRIPT"
    common=$(get_exclusion_patterns common)
    extended=$(get_exclusion_patterns extended)

    # Check that extended includes common patterns
    echo "$extended" | grep -q ":!package-lock.json"
    echo "$extended" | grep -q ":!\*.min.js"
    echo "$extended" | grep -q ":!dist/"
}

@test "extended mode includes snapshot files" {
    source "$SCRIPT"
    result=$(get_exclusion_patterns extended)

    echo "$result" | grep -q ":!\*.ambr"
    echo "$result" | grep -q ":!\*.snap"
    echo "$result" | grep -q ":!\*\*/__snapshots__/\*\*"
}

@test "extended mode includes additional lock files" {
    source "$SCRIPT"
    result=$(get_exclusion_patterns extended)

    echo "$result" | grep -q ":!uv.lock"
    echo "$result" | grep -q ":!poetry.lock"
    echo "$result" | grep -q ":!Gemfile.lock"
}

@test "extended mode includes generated files" {
    source "$SCRIPT"
    result=$(get_exclusion_patterns extended)

    echo "$result" | grep -q ":!\*.pyc"
    echo "$result" | grep -q ":!\*\*/__pycache__/\*\*"
    echo "$result" | grep -q ":!\*.map"
    echo "$result" | grep -q ":!\*.wasm"
}

@test "extended mode includes IDE files" {
    source "$SCRIPT"
    result=$(get_exclusion_patterns extended)

    echo "$result" | grep -q ":!.DS_Store"
    echo "$result" | grep -q ":!\*.swp"
}

@test "default mode is same as common" {
    source "$SCRIPT"
    common=$(get_exclusion_patterns common)
    default=$(get_exclusion_patterns default)

    [ "$common" = "$default" ]
}

@test "common mode returns expected count" {
    source "$SCRIPT"
    count=$(get_exclusion_patterns common | wc -l)

    # Should have 9 patterns (3 lock file groups + 2 minified + 3 build outputs + 1 generated)
    [ "$count" -eq 9 ]
}

@test "extended mode returns more patterns than common" {
    source "$SCRIPT"
    common_count=$(get_exclusion_patterns common | wc -l)
    extended_count=$(get_exclusion_patterns extended | wc -l)

    [ "$extended_count" -gt "$common_count" ]
}

@test "extended mode returns expected count" {
    source "$SCRIPT"
    count=$(get_exclusion_patterns extended | wc -l)

    # Should have 32 total patterns (9 common + 23 extended)
    [ "$count" -eq 32 ]
}

@test "invalid mode returns error" {
    source "$SCRIPT"
    run get_exclusion_patterns invalid_mode

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Error:.*Unknown exclusion mode"
}

@test "invalid mode suggests valid modes" {
    source "$SCRIPT"
    run get_exclusion_patterns invalid_mode

    echo "$output" | grep -q "Valid modes: common, extended"
}

@test "patterns use git pathspec format" {
    source "$SCRIPT"
    result=$(get_exclusion_patterns common)

    # All patterns should start with :!
    while IFS= read -r line; do
        [[ "$line" == :!* ]]
    done <<< "$result"
}

@test "no duplicate patterns in extended mode" {
    source "$SCRIPT"
    result=$(get_exclusion_patterns extended)

    # Count unique lines vs total lines
    unique_count=$(echo "$result" | sort -u | wc -l)
    total_count=$(echo "$result" | wc -l)

    [ "$unique_count" -eq "$total_count" ]
}
