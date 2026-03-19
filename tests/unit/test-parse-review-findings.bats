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

# =============================================================================
# Pattern 5: ### `severity`: Title
# =============================================================================

@test "parse-review-findings.sh: Pattern 5 - blocking severity header" {
    cat > "$TEST_DIR/review.md" << 'EOF'
### `blocking`: IPv6-Mapped IPv4 Address SSRF Bypass
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'length == 1' > /dev/null
    echo "$output" | jq -e '.[0].description | contains("IPv6-Mapped")' > /dev/null
}

@test "parse-review-findings.sh: Pattern 5 - all severity levels" {
    for severity in blocking suggestion nit question; do
        cat > "$TEST_DIR/review.md" << EOF
### \`${severity}\`: Some finding title
EOF
        run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
        [ "$status" -eq 0 ]
        echo "$output" | jq -e 'length == 1' > /dev/null
        echo "$output" | jq -e '.[0].description | contains("Some finding title")' > /dev/null
    done
}

@test "parse-review-findings.sh: Pattern 5 - with ## prefix" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## `suggestion`: Consider using a connection pool
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'length == 1' > /dev/null
    echo "$output" | jq -e '.[0].description | contains("connection pool")' > /dev/null
}

# =============================================================================
# Pattern 6: **File:** `path` (optionally with line info)
# =============================================================================

@test "parse-review-findings.sh: Pattern 6 - File with colon line number" {
    cat > "$TEST_DIR/review.md" << 'EOF'
### `blocking`: Some issue
**File:** `src/auth.py:42`
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].file == "src/auth.py"' > /dev/null
    echo "$output" | jq -e '.[0].line == 42' > /dev/null
}

@test "parse-review-findings.sh: Pattern 6 - File with lines N suffix" {
    cat > "$TEST_DIR/review.md" << 'EOF'
### `suggestion`: Refactor method
**File:** `utils/helpers.py` lines 100
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].file == "utils/helpers.py"' > /dev/null
    echo "$output" | jq -e '.[0].line == 100' > /dev/null
}

@test "parse-review-findings.sh: Pattern 6 - File without line info" {
    cat > "$TEST_DIR/review.md" << 'EOF'
### `nit`: Naming convention
**File:** `config.js`
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].file == "config.js"' > /dev/null
    echo "$output" | jq -e '.[0].line == 0' > /dev/null
}

# =============================================================================
# Relaxed flush (finding saved without file path)
# =============================================================================

@test "parse-review-findings.sh: saves finding without file path" {
    cat > "$TEST_DIR/review.md" << 'EOF'
### `blocking`: Missing rate limiting

The API endpoint lacks rate limiting protection.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'length == 1' > /dev/null
    echo "$output" | jq -e '.[0].file == ""' > /dev/null
    echo "$output" | jq -e '.[0].line == 0' > /dev/null
    echo "$output" | jq -e '.[0].description | contains("rate limiting")' > /dev/null
}

# =============================================================================
# Combined flow: Pattern 5 + Pattern 6 together
# =============================================================================

@test "parse-review-findings.sh: Pattern 5 + 6 combined flow" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

### `blocking`: SQL injection vulnerability
**File:** `api/users.py:78`

User input is passed directly to the query.

### `suggestion`: Add input validation
**File:** `api/users.py` lines 90

Consider sanitizing the input before use.

### `nit`: Rename variable
**File:** `api/helpers.py`

The variable name is unclear.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'length == 3' > /dev/null
    echo "$output" | jq -e '.[0].file == "api/users.py"' > /dev/null
    echo "$output" | jq -e '.[0].line == 78' > /dev/null
    echo "$output" | jq -e '.[0].agent == "security"' > /dev/null
    echo "$output" | jq -e '.[1].file == "api/users.py"' > /dev/null
    echo "$output" | jq -e '.[1].line == 90' > /dev/null
    echo "$output" | jq -e '.[2].file == "api/helpers.py"' > /dev/null
    echo "$output" | jq -e '.[2].line == 0' > /dev/null
}

# =============================================================================
# Sourceable
# =============================================================================

@test "parse-review-findings.sh: can be sourced without executing main" {
    run bash -c "source '$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh' && echo 'sourced ok'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced ok"* ]]
}

# =============================================================================
# Finding number, prefix, title extraction tests
# =============================================================================

@test "parse-review-findings.sh: extracts number, prefix, title from numbered finding" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

### 1. `blocking`: Missing FLAGS_REDIS_URL guard (Architecture, 85%)

**`posthog/storage/team_access_cache.py:22-28`**

Every analogous Redis consumer guards against FLAGS_REDIS_URL being None.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].number == "1"' > /dev/null
    echo "$output" | jq -e '.[0].prefix == "blocking"' > /dev/null
    echo "$output" | jq -e '.[0].title == "Missing FLAGS_REDIS_URL guard"' > /dev/null
}

@test "parse-review-findings.sh: extracts number from #### heading" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Architecture Review

#### 8. `suggestion`: PSAK invalidation on team delete lacks retry safety (Correctness 95% + Architecture 80%, 2 agents)

**`posthog/tasks/team_metadata.py:158-160`**

When a team is deleted, PSAKs are invalidated via direct call.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].number == "8"' > /dev/null
    echo "$output" | jq -e '.[0].prefix == "suggestion"' > /dev/null
    echo "$output" | jq -e '.[0].title == "PSAK invalidation on team delete lacks retry safety"' > /dev/null
}

@test "parse-review-findings.sh: extracts Q-prefix question number" {
    cat > "$TEST_DIR/review.md" << 'EOF'
### Q1: Does the Rust service use secure_value directly? (Security, 50%)

**`posthog/models/remote_config.py:664-668`**

Some question about the Rust service.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].number == "Q1"' > /dev/null
    echo "$output" | jq -e '.[0].prefix == "question"' > /dev/null
    echo "$output" | jq -e '.[0].title == "Does the Rust service use secure_value directly?"' > /dev/null
}

@test "parse-review-findings.sh: extracts N-prefix nit number" {
    cat > "$TEST_DIR/review.md" << 'EOF'
### N2: Token hash prefix logging shows only 5 hash chars

**`posthog/storage/team_access_cache.py:49`**

token_hash[:12] on a sha256$hex value yields too short a prefix.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].number == "N2"' > /dev/null
    echo "$output" | jq -e '.[0].prefix == "nit"' > /dev/null
    echo "$output" | jq -e '.[0].title == "Token hash prefix logging shows only 5 hash chars"' > /dev/null
}

@test "parse-review-findings.sh: numbered heading followed by Pattern 1 location produces single finding" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

### 1. `blocking`: Missing input validation

#### `src/handlers/auth.py:45`

The function does not validate the token format before passing it to the database query.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    # Should produce exactly one finding, not two
    echo "$output" | jq -e 'length == 1' > /dev/null
    echo "$output" | jq -e '.[0].number == "1"' > /dev/null
    echo "$output" | jq -e '.[0].prefix == "blocking"' > /dev/null
    echo "$output" | jq -e '.[0].title == "Missing input validation"' > /dev/null
    echo "$output" | jq -e '.[0].file == "src/handlers/auth.py"' > /dev/null
    echo "$output" | jq -e '.[0].line == 45' > /dev/null
}

@test "parse-review-findings.sh: finding without number has null number" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

### `blocking`: Some unnamed finding

Some description.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].number == null' > /dev/null
    echo "$output" | jq -e '.[0].prefix == "blocking"' > /dev/null
}

# =============================================================================
# CONCLUSION extraction tests
# =============================================================================

@test "parse-review-findings.sh: extracts CONCLUSION: Fixed" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

### 1. `blocking`: Missing guard

**`posthog/storage/cache.py:22`**

Every analogous consumer guards against this.

CONCLUSION: Fixed
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].conclusion.status == "Fixed"' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.reason == null' > /dev/null
}

@test "parse-review-findings.sh: extracts CONCLUSION with reason" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Architecture Review

### 5. `suggestion`: Unconditional invalidation on full save

**`posthog/models/remote_config.py:637-641`**

When update_fields=None, the handler always calls schedule_fn.

CONCLUSION: Fixed - removed dead code instead
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].conclusion.status == "Fixed"' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.reason == "removed dead code instead"' > /dev/null
}

@test "parse-review-findings.sh: extracts CONCLUSION: Won't fix" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Performance Review

### 2. `suggestion`: Error count semantics differ

**`src/flags.rs:90`**

The error_count semantics differ between paths.

CONCLUSION: Won't fix - not worth the complexity
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].conclusion.status == "Won'\''t fix"' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.reason == "not worth the complexity"' > /dev/null
}

@test "parse-review-findings.sh: extracts CONCLUSION: Invalid" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Correctness Review

### 3. `blocking`: Race condition on cache

**`posthog/cache.py:50`**

Potential race condition.

CONCLUSION: Invalid - false positive, guard exists upstream
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].conclusion.status == "Invalid"' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.reason == "false positive, guard exists upstream"' > /dev/null
}

@test "parse-review-findings.sh: extracts CONCLUSION: Deferred" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Testing Review

### 4. `suggestion`: Add integration test

**`tests/test_cache.py:100`**

Missing integration test for this path.

CONCLUSION: Deferred - will address in follow-up PR
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].conclusion.status == "Deferred"' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.reason == "will address in follow-up PR"' > /dev/null
}

@test "parse-review-findings.sh: extracts freeform CONCLUSION" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Performance Review

### 2. `suggestion`: Error count semantics

**`src/flags.rs:90`**

Semantics differ between paths.

CONCLUSION: NOT WORTH FIXING
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].conclusion.status == "NOT WORTH FIXING"' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.reason == null' > /dev/null
}

@test "parse-review-findings.sh: no conclusion yields null" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

### 6. `suggestion`: Signal handler split

**`posthog/models/remote_config.py:596-772`**

Signal handlers are split across two files.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].conclusion == null' > /dev/null
}

@test "parse-review-findings.sh: case-insensitive CONCLUSION matching" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

### 1. `blocking`: Some issue

**`auth.py:10`**

Description.

Conclusion: Fixed
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].conclusion.status == "Fixed"' > /dev/null
}

@test "parse-review-findings.sh: CONCLUSION does not leak into next finding" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Security Review

### 1. `blocking`: First issue

**`auth.py:10`**

Description of first issue.

CONCLUSION: Fixed

### 2. `suggestion`: Second issue

**`auth.py:20`**

Description of second issue.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'length == 2' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.status == "Fixed"' > /dev/null
    echo "$output" | jq -e '.[1].conclusion == null' > /dev/null
}

# =============================================================================
# Real-world format: haacked-build-auth-cache.md style
# =============================================================================

@test "parse-review-findings.sh: real-world numbered finding with bold file ref" {
    cat > "$TEST_DIR/review.md" << 'EOF'
## Blocking Findings

### 1. `blocking`: Missing FLAGS_REDIS_URL guard in _get_redis_client (Architecture, 85%)

**`posthog/storage/team_access_cache.py:22-28`**

Every analogous Redis consumer in the codebase guards against FLAGS_REDIS_URL.

CONCLUSION: Fixed.

---

## Corroborated Suggestions

### 2. `suggestion`: capture_old_secret_tokens missing _state.adding check (Security + Performance, 3 agents)

**`posthog/storage/team_access_cache_signal_handlers.py:75-76`**

The function only checks not instance.pk.

CONCLUSION: Fixed

---

## Solo Suggestions

### 6. `suggestion`: Signal handler registration split across modules (Maintainability, 60%)

**`posthog/models/remote_config.py:596-772`**

A maintainer has to check both files.
EOF
    run "$PROJECT_ROOT/skills/review-code/scripts/parse-review-findings.sh" "$TEST_DIR/review.md"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'length == 3' > /dev/null

    # Finding 1: concluded
    echo "$output" | jq -e '.[0].number == "1"' > /dev/null
    echo "$output" | jq -e '.[0].prefix == "blocking"' > /dev/null
    echo "$output" | jq -e '.[0].conclusion.status == "Fixed"' > /dev/null

    # Finding 2: concluded
    echo "$output" | jq -e '.[1].number == "2"' > /dev/null
    echo "$output" | jq -e '.[1].prefix == "suggestion"' > /dev/null
    echo "$output" | jq -e '.[1].conclusion.status == "Fixed"' > /dev/null

    # Finding 6: open
    echo "$output" | jq -e '.[2].number == "6"' > /dev/null
    echo "$output" | jq -e '.[2].prefix == "suggestion"' > /dev/null
    echo "$output" | jq -e '.[2].conclusion == null' > /dev/null
}
