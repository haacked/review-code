#!/usr/bin/env bats
# Security tests for path traversal prevention in review-file-path.sh

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

    # Source the script to test sanitize_path_component function
    # We need to extract just the function for testing
    source "$PROJECT_ROOT/lib/review-file-path.sh"
}

# Test sanitize_path_component function directly

@test "sanitize_path_component: rejects absolute paths" {
    run sanitize_path_component "/etc/passwd"

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Absolute paths not allowed"
}

@test "sanitize_path_component: rejects double dots" {
    run sanitize_path_component "../etc"

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Path traversal sequences not allowed"
}

@test "sanitize_path_component: rejects triple dots" {
    run sanitize_path_component "..."

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Path traversal sequences not allowed"
}

@test "sanitize_path_component: rejects quadruple dots" {
    run sanitize_path_component "...."

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Path traversal sequences not allowed"
}

@test "sanitize_path_component: rejects dots in middle" {
    run sanitize_path_component "test..test"

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Path traversal sequences not allowed"
}

@test "sanitize_path_component: rejects starting with dot" {
    run sanitize_path_component ".hidden"

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "cannot start with dot"
}

@test "sanitize_path_component: rejects starting with dash" {
    run sanitize_path_component "-weird"

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "cannot start with dot or dash"
}

@test "sanitize_path_component: rejects empty string" {
    run sanitize_path_component ""

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Empty path component"
}

@test "sanitize_path_component: converts slashes to dashes" {
    result=$(sanitize_path_component "haacked/feature")

    [ "$result" = "haacked-feature" ]
}

@test "sanitize_path_component: allows safe alphanumeric" {
    result=$(sanitize_path_component "test123")

    [ "$result" = "test123" ]
}

@test "sanitize_path_component: allows underscores" {
    result=$(sanitize_path_component "test_branch")

    [ "$result" = "test_branch" ]
}

@test "sanitize_path_component: allows dots in middle" {
    result=$(sanitize_path_component "test.branch")

    [ "$result" = "test.branch" ]
}

@test "sanitize_path_component: removes special characters" {
    result=$(sanitize_path_component "test@#\$%branch")

    [ "$result" = "testbranch" ]
}

@test "sanitize_path_component: rejects if empty after filtering" {
    run sanitize_path_component "@#\$%^&*()"

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "became empty after sanitization"
}

# Test complex attack scenarios

@test "sanitize_path_component: safely handles URL-encoded traversal" {
    # %2e%2e is .. in URL encoding
    # After filtering special chars, becomes just "2e2e" which is safe
    result=$(sanitize_path_component "%2e%2e")

    [ "$result" = "2e2e" ]
}

@test "sanitize_path_component: rejects mixed slashes and dots" {
    run sanitize_path_component "../../../etc"

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Path traversal"
}

@test "sanitize_path_component: rejects embedded traversal" {
    run sanitize_path_component "test/../etc"

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Path traversal"
}

@test "sanitize_path_component: rejects symlink-like names" {
    # Names that could be symlinks
    run sanitize_path_component ".."

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Path traversal"
}

@test "sanitize_path_component: rejects single dot" {
    run sanitize_path_component "."

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "cannot start with dot"
}

@test "sanitize_path_component: handles valid branch names" {
    result=$(sanitize_path_component "feature-branch")

    [ "$result" = "feature-branch" ]
}

@test "sanitize_path_component: handles valid org names" {
    result=$(sanitize_path_component "PostHog")

    [ "$result" = "PostHog" ]
}

@test "sanitize_path_component: handles commit hashes" {
    result=$(sanitize_path_component "a1b2c3d4")

    [ "$result" = "a1b2c3d4" ]
}

@test "sanitize_path_component: handles PR numbers" {
    result=$(sanitize_path_component "123")

    [ "$result" = "123" ]
}

# Test that the function is deterministic

@test "sanitize_path_component: is deterministic" {
    result1=$(sanitize_path_component "test-branch")
    result2=$(sanitize_path_component "test-branch")

    [ "$result1" = "$result2" ]
}

@test "sanitize_path_component: preserves case" {
    result=$(sanitize_path_component "TestBranch")

    [ "$result" = "TestBranch" ]
}
