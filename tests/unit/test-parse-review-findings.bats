#!/usr/bin/env bats
# Tests for parse-review-findings.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create temporary directory for test review files
    TEST_DIR=$(mktemp -d)
    export TEST_DIR
}

teardown() {
    rm -rf "$TEST_DIR"
}

# =============================================================================
# Basic functionality tests
# =============================================================================

@test "parse-review-findings.sh: exists and is executable" {
    [ -x "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" ]
}

@test "parse-review-findings.sh: requires file argument" {
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "parse-review-findings.sh: errors on non-existent file" {
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "/nonexistent/file.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "parse-review-findings.sh: returns empty array for empty file" {
    echo "" > "$TEST_DIR/empty.md"
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/empty.md"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

# =============================================================================
# Agent section header detection tests
# =============================================================================

@test "parse-review-findings.sh: detects Security Review header" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `auth.py:45`

SQL injection vulnerability
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].agent == "security"' > /dev/null
}

@test "parse-review-findings.sh: detects Performance Review header" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Performance Review

#### `query.py:100`

N+1 query detected
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].agent == "performance"' > /dev/null
}

@test "parse-review-findings.sh: detects all agent types" {
    for agent in Security Performance Correctness Maintainability Testing Compatibility Architecture Frontend; do
        cat > "$TEST_DIR/review.md" << EOF
## ${agent} Review

#### \`file.py:1\`

Finding for ${agent}
EOF
        run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
        [ "$status" -eq 0 ]
        local lower_agent
        lower_agent=$(echo "$agent" | tr '[:upper:]' '[:lower:]')
        echo "$output" | jq -e ".[0].agent == \"$lower_agent\"" > /dev/null
    done
}

# =============================================================================
# File:line pattern tests
# =============================================================================

@test "parse-review-findings.sh: Pattern 1 - #### backtick file:line" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `src/auth/login.py:123`

This is a security issue
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].file == "src/auth/login.py"' > /dev/null
    echo "$output" | jq -e '.[0].line == 123' > /dev/null
}

@test "parse-review-findings.sh: Pattern 2 - bullet with bold backtick file:line" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

- **`config.js:42`**: Hardcoded credentials detected
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].file == "config.js"' > /dev/null
    echo "$output" | jq -e '.[0].line == 42' > /dev/null
    echo "$output" | jq -e '.[0].description | contains("Hardcoded credentials")' > /dev/null
}

@test "parse-review-findings.sh: Pattern 3 - Location: backtick file:line" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Performance Review

**Location**: `database/queries.py:256`

Inefficient query pattern
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].file == "database/queries.py"' > /dev/null
    echo "$output" | jq -e '.[0].line == 256' > /dev/null
}

@test "parse-review-findings.sh: Pattern 4 - [Agent NN%] description (file:line)" {
    cat > "$TEST_DIR/review.md" << 'EOF'
[Security 85%] SQL injection risk (api/users.py:78)
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].agent == "security"' > /dev/null
    echo "$output" | jq -e '.[0].confidence == 85' > /dev/null
    echo "$output" | jq -e '.[0].file == "api/users.py"' > /dev/null
    echo "$output" | jq -e '.[0].line == 78' > /dev/null
}

# =============================================================================
# Confidence marker tests
# =============================================================================

@test "parse-review-findings.sh: extracts [NN%] confidence" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `auth.py:45`

[75%] Possible XSS vulnerability
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].confidence == 75' > /dev/null
}

@test "parse-review-findings.sh: extracts (NN% confidence) format" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `auth.py:45`

(90% confidence) Critical security issue
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].confidence == 90' > /dev/null
}

@test "parse-review-findings.sh: confidence in inline pattern" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

- **`config.js:42`**: Hardcoded credentials detected [85%]
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].confidence == 85' > /dev/null
}

@test "parse-review-findings.sh: defaults confidence to 0 when missing" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `auth.py:45`

Issue without confidence marker
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].confidence == 0' > /dev/null
}

# =============================================================================
# Multiple findings tests
# =============================================================================

@test "parse-review-findings.sh: extracts multiple findings" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `auth.py:45`

First security issue

#### `login.py:100`

Second security issue

## Performance Review

#### `query.py:200`

Performance issue
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'length == 3' > /dev/null
    echo "$output" | jq -e '.[0].file == "auth.py"' > /dev/null
    echo "$output" | jq -e '.[1].file == "login.py"' > /dev/null
    echo "$output" | jq -e '.[2].file == "query.py"' > /dev/null
}

@test "parse-review-findings.sh: handles mixed patterns in same file" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `auth.py:45`

Pattern 1 finding

- **`config.js:42`**: Pattern 2 finding

**Location**: `db.py:100`

Pattern 3 finding

[Security 85%] Pattern 4 finding (api.py:200)
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'length == 4' > /dev/null
}

# =============================================================================
# Description accumulation tests
# =============================================================================

@test "parse-review-findings.sh: accumulates multi-line descriptions" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `auth.py:45`

This is line one of the description.
This is line two.
This is line three.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].description | contains("line one")' > /dev/null
    echo "$output" | jq -e '.[0].description | contains("line two")' > /dev/null
}

@test "parse-review-findings.sh: truncates very long descriptions" {
    # Generate a description longer than 500 chars
    local long_desc
    long_desc=$(printf 'a%.0s' {1..600})
    cat > "$TEST_DIR/review.md" << EOF
## Security Review

#### \`auth.py:45\`

${long_desc}
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    # Description should be truncated to 500 chars
    local desc_len
    desc_len=$(echo "$output" | jq -r '.[0].description | length')
    [ "$desc_len" -le 500 ]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "parse-review-findings.sh: handles file paths with special characters" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `src/components/user-auth.tsx:45`

Issue in TypeScript file
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].file == "src/components/user-auth.tsx"' > /dev/null
}

@test "parse-review-findings.sh: handles deeply nested file paths" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `a/b/c/d/e/f/file.py:1`

Deep nesting
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].file == "a/b/c/d/e/f/file.py"' > /dev/null
}

@test "parse-review-findings.sh: assigns unknown agent when no section header" {
    cat > "$TEST_DIR/review.md" << 'EOF'
#### `auth.py:45`

Finding without agent section
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].agent == "unknown"' > /dev/null
}

@test "parse-review-findings.sh: produces valid JSON" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

#### `auth.py:45`

[85%] Security issue

## Performance Review

#### `query.py:100`

(75% confidence) Performance issue
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    # Validate JSON structure
    echo "$output" | jq . > /dev/null
    echo "$output" | jq -e 'type == "array"' > /dev/null
    echo "$output" | jq -e 'all(.[]; has("agent") and has("confidence") and has("file") and has("line") and has("description"))' > /dev/null
}

@test "parse-review-findings.sh: can be sourced without executing main" {
    run bash -c "source '$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh' && echo 'sourced ok'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced ok"* ]]
}
