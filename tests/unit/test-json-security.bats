#!/usr/bin/env bats
# Security tests for JSON injection prevention

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    PARSE_REVIEW_ARG="$PROJECT_ROOT/skills/review-code/scripts/parse-review-arg.sh"
}

# Test that JSON output is always valid even with malicious input
@test "parse-review-arg: rejects JSON injection in argument" {
    run "$PARSE_REVIEW_ARG" 'test","evil":"injection'

    # Should fail (invalid git ref)
    [ "$status" -eq 1 ]

    # Output should still be valid JSON
    echo "$output" | jq . > /dev/null

    # Should not contain the injected field
    ! echo "$output" | jq -e '.evil' > /dev/null
}

@test "parse-review-arg: escapes quotes in error messages" {
    run "$PARSE_REVIEW_ARG" 'test"with"quotes'

    [ "$status" -eq 1 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null

    # Quotes should be properly escaped in error message
    echo "$output" | jq -e '.error | contains("test\"with\"quotes")' > /dev/null
}

@test "parse-review-arg: handles newlines safely" {
    run "$PARSE_REVIEW_ARG" 'test\ntest'

    [ "$status" -eq 1 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null
}

@test "parse-review-arg: handles backslashes safely" {
    run "$PARSE_REVIEW_ARG" 'test\\test'

    [ "$status" -eq 1 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null
}

@test "parse-review-arg: area keyword produces valid JSON" {
    run "$PARSE_REVIEW_ARG" security

    [ "$status" -eq 0 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null

    # Should have correct fields
    echo "$output" | jq -e '.mode == "area"' > /dev/null
    echo "$output" | jq -e '.area == "security"' > /dev/null
}

@test "parse-review-arg: PR number produces valid JSON" {
    run "$PARSE_REVIEW_ARG" 123

    [ "$status" -eq 0 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null

    # Should have correct fields
    echo "$output" | jq -e '.mode == "pr"' > /dev/null
    echo "$output" | jq -e '.pr_number == "123"' > /dev/null
}

@test "parse-review-arg: file pattern with special chars produces valid JSON" {
    run "$PARSE_REVIEW_ARG" security '**/*.sh'

    [ "$status" -eq 0 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null

    # Should have correct fields
    echo "$output" | jq -e '.file_pattern == "**/*.sh"' > /dev/null
}

@test "parse-review-arg: file pattern injection attempt fails" {
    run "$PARSE_REVIEW_ARG" security 'test.sh","evil":"injected'

    [ "$status" -eq 0 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null

    # File pattern should be treated as literal string (with escaped quotes)
    echo "$output" | jq -r '.file_pattern' | grep -q 'test.sh","evil":"injected'

    # Should not have injected field
    ! echo "$output" | jq -e '.evil' > /dev/null
}

@test "parse-review-arg: handles control characters safely" {
    # Test with tab, carriage return, and other control chars
    run "$PARSE_REVIEW_ARG" $'test\ttab\rcarriage'

    [ "$status" -eq 1 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null
}

@test "parse-review-arg: handles unicode safely" {
    run "$PARSE_REVIEW_ARG" 'test-emoji-🔒-unicode'

    [ "$status" -eq 1 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null

    # Error message should contain the unicode
    echo "$output" | jq -e '.error | contains("🔒")' > /dev/null
}

@test "parse-review-arg: handles null bytes safely" {
    # Bash will truncate at null byte, but should still be safe
    run "$PARSE_REVIEW_ARG" $'test\0null'

    # Output should be valid JSON (even if input was truncated)
    echo "$output" | jq . > /dev/null
}

@test "parse-review-arg: no command substitution in JSON" {
    # Attempt command substitution
    run "$PARSE_REVIEW_ARG" '$(whoami)'

    [ "$status" -eq 1 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null

    # Should not execute the command (whoami result should not appear)
    ! echo "$output" | jq . | grep -q "$(whoami)"
}

@test "parse-review-arg: no shell expansion in JSON" {
    # Attempt shell variable expansion
    run "$PARSE_REVIEW_ARG" '$HOME'

    [ "$status" -eq 1 ]

    # Output should be valid JSON
    echo "$output" | jq . > /dev/null

    # Should contain literal $HOME, not expanded path
    echo "$output" | jq -e '.error | contains("$HOME")' > /dev/null
}
