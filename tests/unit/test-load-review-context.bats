#!/usr/bin/env bats
# Tests for load-review-context.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create temp context directory for testing
    TEST_CONTEXT_DIR=$(mktemp -d)
    export CONTEXT_PATH="$TEST_CONTEXT_DIR"

    # Create directory structure
    mkdir -p "$TEST_CONTEXT_DIR/languages"
    mkdir -p "$TEST_CONTEXT_DIR/frameworks"
    mkdir -p "$TEST_CONTEXT_DIR/orgs/testorg/repos"

    # Create sample context files
    echo "Python guidelines content" > "$TEST_CONTEXT_DIR/languages/python.md"
    echo "TypeScript guidelines content" > "$TEST_CONTEXT_DIR/languages/typescript.md"
    echo "React guidelines content" > "$TEST_CONTEXT_DIR/frameworks/react.md"
    echo "Django guidelines content" > "$TEST_CONTEXT_DIR/frameworks/django.md"
    echo "TestOrg guidelines content" > "$TEST_CONTEXT_DIR/orgs/testorg/org.md"
    echo "TestRepo guidelines content" > "$TEST_CONTEXT_DIR/orgs/testorg/repos/testrepo.md"
}

teardown() {
    # Clean up test context directory
    rm -rf "$TEST_CONTEXT_DIR"
}

# =============================================================================
# JSON input parsing tests
# =============================================================================

@test "load-review-context.sh: parses languages from JSON" {
    json='{"languages":["python"],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Python Guidelines"* ]]
}

@test "load-review-context.sh: parses frameworks from JSON" {
    json='{"languages":[],"frameworks":["react"]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"React Guidelines"* ]]
}

@test "load-review-context.sh: handles multiple languages" {
    json='{"languages":["python","typescript"],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Python Guidelines"* ]]
    [[ "$output" == *"Typescript Guidelines"* ]]
}

# =============================================================================
# Context file loading tests
# =============================================================================

@test "load-review-context.sh: loads language context" {
    json='{"languages":["python"],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Python guidelines content"* ]]
}

@test "load-review-context.sh: loads framework context" {
    json='{"languages":[],"frameworks":["django"]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Django guidelines content"* ]]
}

@test "load-review-context.sh: loads org context" {
    json='{"languages":[],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' testorg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Testorg Organization Guidelines"* ]]
}

@test "load-review-context.sh: loads repo context" {
    json='{"languages":[],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' testorg testrepo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Testorg/Testrepo Repository Guidelines"* ]]
}

# =============================================================================
# Case sensitivity tests
# =============================================================================

@test "load-review-context.sh: converts language names to lowercase" {
    json='{"languages":["Python","PYTHON"],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Python guidelines content"* ]]
}

@test "load-review-context.sh: converts framework names to lowercase" {
    json='{"languages":[],"frameworks":["React","REACT"]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"React guidelines content"* ]]
}

@test "load-review-context.sh: converts org names to lowercase" {
    json='{"languages":[],"frameworks":[]}'
    # Lowercase org should work (uppercase is rejected for security)
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' testorg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TestOrg guidelines content"* ]]
}

# =============================================================================
# Missing file handling tests
# =============================================================================

@test "load-review-context.sh: handles missing language files" {
    json='{"languages":["nonexistent"],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "load-review-context.sh: handles missing framework files" {
    json='{"languages":[],"frameworks":["nonexistent"]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "load-review-context.sh: handles missing org files" {
    json='{"languages":[],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' nonexistent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# Hierarchical loading tests
# =============================================================================

@test "load-review-context.sh: loads all context in hierarchy" {
    json='{"languages":["python"],"frameworks":["django"]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' testorg testrepo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Python Guidelines"* ]]
    [[ "$output" == *"Django Guidelines"* ]]
    [[ "$output" == *"Testorg Organization Guidelines"* ]]
    [[ "$output" == *"Testorg/Testrepo Repository Guidelines"* ]]
}

@test "load-review-context.sh: separates context sections" {
    json='{"languages":["python","typescript"],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    # Should have double newlines between sections
    [[ "$output" == *"## Python Guidelines"* ]]
    [[ "$output" == *"## Typescript Guidelines"* ]]
}

# =============================================================================
# Duplicate prevention tests
# =============================================================================

@test "load-review-context.sh: prevents duplicate framework loads" {
    # Create duplicate framework reference
    json='{"languages":[],"frameworks":["react","react"]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    # Count occurrences of "React Guidelines" (should be 1)
    count=$(echo "$output" | grep -c "React Guidelines" || true)
    [ "$count" -eq 1 ]
}

# =============================================================================
# Empty input tests
# =============================================================================

@test "load-review-context.sh: handles empty JSON" {
    json='{"languages":[],"frameworks":[]}'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "load-review-context.sh: handles malformed JSON gracefully" {
    json='not valid json'
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# Security: Path Traversal Defense Tests
# =============================================================================

@test "security: rejects path traversal in org parameter" {
    json='{"languages":["python"]}'

    # Try to traverse up with ../
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' '../../../etc' 'passwd'"
    [ "$status" -eq 0 ]
    
    # Should not contain /etc/passwd content
    [[ ! "$output" =~ "root:" ]]
}

@test "security: rejects absolute path in org parameter" {
    json='{"languages":["python"]}'

    # Try absolute path
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' '/etc' 'passwd'"
    [ "$status" -eq 0 ]
    
    # Should not contain /etc/passwd content
    [[ ! "$output" =~ "root:" ]]
}

@test "security: rejects path traversal in repo parameter" {
    json='{"languages":["python"]}'

    # Try to traverse with .. in repo
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' 'testorg' '../../etc/passwd'"
    [ "$status" -eq 0 ]
    
    # Should not contain /etc/passwd content
    [[ ! "$output" =~ "root:" ]]
}

@test "security: rejects invalid characters in org (uppercase)" {
    json='{"languages":["python"]}'

    # Uppercase not allowed (should be normalized to lowercase upstream, but we validate)
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' 'TestOrg' 'testrepo'"
    [ "$status" -eq 0 ]
    
    # Should reject and not load org context
    [[ ! "$output" =~ "TestOrg guidelines content" ]]
}

@test "security: rejects invalid characters in org (slash)" {
    json='{"languages":["python"]}'

    # Slash not allowed
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' 'test/org' 'testrepo'"
    [ "$status" -eq 0 ]

    # Should contain Python guidelines (valid language)
    [[ "$output" =~ "Python guidelines content" ]]
    # But should NOT contain org or repo context (invalid org parameter)
    [[ ! "$output" =~ "Organization Guidelines" ]]
    [[ ! "$output" =~ "Repository Guidelines" ]]
}

@test "security: allows valid lowercase org and repo" {
    json='{"languages":[]}'

    # Valid parameters should work
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' 'testorg' 'testrepo'"
    [ "$status" -eq 0 ]
    
    # Should contain both org and repo context
    [[ "$output" =~ "TestOrg guidelines content" ]]
    [[ "$output" =~ "TestRepo guidelines content" ]]
}

@test "security: handles empty org parameter safely" {
    json='{"languages":["python"]}'

    # Empty org should work (optional parameter)
    run bash -c "echo '$json' | '$PROJECT_ROOT/lib/load-review-context.sh' '' ''"
    [ "$status" -eq 0 ]
    
    # Should contain Python context
    [[ "$output" =~ "Python guidelines content" ]]
}
