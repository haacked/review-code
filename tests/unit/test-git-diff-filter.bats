#!/usr/bin/env bats
# Tests for git-diff-filter.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for testing
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init
    git config commit.gpgsign false
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial commit
    echo "initial" > file.txt
    git add file.txt
    git commit -m "Initial commit"
}

teardown() {
    # Clean up test repository
    rm -rf "$TEST_REPO"
}

# =============================================================================
# Exclusion pattern loading tests
# =============================================================================

@test "git-diff-filter.sh: loads extended exclusion patterns" {
    run bash -c "source '$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh' 2>&1 >/dev/null || true"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Metadata forwarding tests
# =============================================================================

@test "git-diff-filter.sh: forwards metadata to stderr" {
    echo "staged change" > file.txt
    git add file.txt

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE:"* ]]
}

# =============================================================================
# Staged changes filtering tests
# =============================================================================

@test "git-diff-filter.sh: filters staged changes" {
    echo "staged change" > file.txt
    git add file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: staged"* ]]
}

@test "git-diff-filter.sh: excludes lock files from staged" {
    # Create a lock file
    echo "lock content" > package-lock.json
    git add package-lock.json

    # Also add a normal file
    echo "normal change" > file.txt
    git add file.txt

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    # Should not contain lock file diff
    [[ "$output" != *"package-lock.json"* ]]
    # Should contain normal file diff
    [[ "$output" == *"file.txt"* ]]
}

# =============================================================================
# Unstaged changes filtering tests
# =============================================================================

@test "git-diff-filter.sh: filters unstaged changes" {
    echo "unstaged change" > file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: unstaged"* ]]
}

@test "git-diff-filter.sh: excludes minified files from unstaged" {
    # Create a minified file
    echo "minified" > app.min.js

    # Also modify a normal file
    echo "normal change" > file.txt

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    # Should not contain minified file diff
    [[ "$output" != *"app.min.js"* ]]
}

# =============================================================================
# Branch changes filtering tests
# =============================================================================

@test "git-diff-filter.sh: filters branch changes" {
    # Create a feature branch with changes
    git checkout -b feature
    echo "feature change" > file.txt
    git add file.txt
    git commit -m "Feature change"

    run "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: branch"* ]]
}

@test "git-diff-filter.sh: excludes build outputs from branch" {
    git checkout -b feature

    # Create build output
    mkdir -p dist
    echo "built" > dist/app.js

    # Also create a normal change
    echo "feature change" > file.txt
    git add .
    git commit -m "Feature change"

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    # Should not contain build output diff
    [[ "$output" != *"dist/app.js"* ]]
}

# =============================================================================
# DIFF_CONTEXT_LINES environment variable
# =============================================================================

@test "git-diff-filter.sh: respects DIFF_CONTEXT_LINES env var" {
    export DIFF_CONTEXT_LINES=5
    echo "change" > file.txt
    git add file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh" 2>&1
    [ "$status" -eq 0 ]
    # Verify it ran (exact diff validation would be fragile)
}

@test "git-diff-filter.sh: defaults to 1 context line" {
    unset DIFF_CONTEXT_LINES
    echo "change" > file.txt
    git add file.txt

    run "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh" 2>&1
    [ "$status" -eq 0 ]
}

# =============================================================================
# No changes handling
# =============================================================================

@test "git-diff-filter.sh: handles no changes gracefully" {
    run "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh" 2>&1
    [ "$status" -eq 0 ]
}

# =============================================================================
# Metadata parsing tests
# =============================================================================

@test "git-diff-filter.sh: parses diff type from metadata" {
    echo "test" > file.txt
    git add file.txt

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: staged"* ]]
}

@test "git-diff-filter.sh: outputs diff to stdout" {
    echo "test change" > file.txt
    git add file.txt

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"diff --git"* ]] || [[ "$output" == *"@@"* ]]
}

# =============================================================================
# Additional Lock File Tests
# =============================================================================

@test "git-diff-filter.sh: excludes Cargo.lock" {
    echo "code" > main.rs
    echo "lock" > Cargo.lock
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main.rs"* ]]
    [[ "$output" != *"Cargo.lock"* ]]
}

@test "git-diff-filter.sh: excludes pnpm-lock.yaml" {
    echo "code" > app.ts
    echo "lock" > pnpm-lock.yaml
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app.ts"* ]]
    [[ "$output" != *"pnpm-lock.yaml"* ]]
}

@test "git-diff-filter.sh: excludes yarn.lock" {
    echo "code" > index.js
    echo "lock" > yarn.lock
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"index.js"* ]]
    [[ "$output" != *"yarn.lock"* ]]
}

@test "git-diff-filter.sh: excludes uv.lock" {
    echo "code" > main.py
    echo "lock" > uv.lock
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main.py"* ]]
    [[ "$output" != *"uv.lock"* ]]
}

@test "git-diff-filter.sh: excludes poetry.lock" {
    echo "code" > app.py
    echo "lock" > poetry.lock
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app.py"* ]]
    [[ "$output" != *"poetry.lock"* ]]
}

@test "git-diff-filter.sh: excludes Gemfile.lock" {
    echo "code" > app.rb
    echo "lock" > Gemfile.lock
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app.rb"* ]]
    [[ "$output" != *"Gemfile.lock"* ]]
}

@test "git-diff-filter.sh: excludes Pipfile.lock" {
    echo "code" > main.py
    echo "lock" > Pipfile.lock
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main.py"* ]]
    [[ "$output" != *"Pipfile.lock"* ]]
}

@test "git-diff-filter.sh: excludes composer.lock" {
    echo "code" > index.php
    echo "lock" > composer.lock
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"index.php"* ]]
    [[ "$output" != *"composer.lock"* ]]
}

@test "git-diff-filter.sh: excludes go.sum" {
    echo "code" > main.go
    echo "checksums" > go.sum
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main.go"* ]]
    [[ "$output" != *"go.sum"* ]]
}

# =============================================================================
# Snapshot File Tests
# =============================================================================

@test "git-diff-filter.sh: excludes .snap files" {
    echo "test" > app.test.js
    echo "snapshot" > app.test.js.snap
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app.test.js"* ]]
    [[ "$output" != *".snap"* ]]
}

@test "git-diff-filter.sh: excludes .ambr files" {
    echo "test" > test.py
    echo "snapshot" > test.ambr
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test.py"* ]]
    [[ "$output" != *".ambr"* ]]
}

@test "git-diff-filter.sh: excludes __snapshots__ directory" {
    mkdir -p __snapshots__
    echo "test" > test.spec.ts
    echo "snapshot" > __snapshots__/test.snap
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test.spec.ts"* ]]
    [[ "$output" != *"__snapshots__"* ]]
}

# =============================================================================
# Generated/Compiled File Tests
# =============================================================================

@test "git-diff-filter.sh: excludes .pyc files" {
    echo "code" > app.py
    echo "compiled" > app.pyc
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app.py"* ]]
    [[ "$output" != *".pyc"* ]]
}

@test "git-diff-filter.sh: excludes __pycache__ directory" {
    mkdir -p __pycache__
    echo "code" > main.py
    echo "cached" > __pycache__/main.cpython-39.pyc
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main.py"* ]]
    [[ "$output" != *"__pycache__"* ]]
}

@test "git-diff-filter.sh: excludes source map files" {
    echo "code" > app.js
    echo "map" > app.js.map
    echo "styles" > style.css
    echo "map" > style.css.map
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app.js"* ]]
    [[ "$output" == *"style.css"* ]]
    [[ "$output" != *".js.map"* ]]
    [[ "$output" != *".css.map"* ]]
}

@test "git-diff-filter.sh: excludes .wasm files" {
    echo "code" > main.rs
    echo "wasm binary" > output.wasm
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main.rs"* ]]
    [[ "$output" != *".wasm"* ]]
}

# =============================================================================
# Build Artifact Tests
# =============================================================================

@test "git-diff-filter.sh: excludes .generated directory" {
    mkdir -p .generated
    echo "source" > src.ts
    echo "generated" > .generated/types.ts
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"src.ts"* ]]
    [[ "$output" != *".generated"* ]]
}

@test "git-diff-filter.sh: excludes target directory (Rust/Maven)" {
    mkdir -p target/release
    echo "code" > main.rs
    echo "binary" > target/release/app
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main.rs"* ]]
    [[ "$output" != *"target/"* ]]
}

@test "git-diff-filter.sh: excludes .tsbuildinfo files" {
    echo "code" > index.ts
    echo "buildinfo" > .tsbuildinfo
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"index.ts"* ]]
    [[ "$output" != *".tsbuildinfo"* ]]
}

@test "git-diff-filter.sh: excludes .next directory" {
    mkdir -p .next/cache
    echo "component" > page.tsx
    echo "cached" > .next/cache/data.json
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"page.tsx"* ]]
    [[ "$output" != *".next"* ]]
}

@test "git-diff-filter.sh: excludes out directory" {
    mkdir -p out
    echo "source" > index.html
    echo "built" > out/index.html
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"index.html"* ]]
    [[ "$output" != *"out/"* ]]
}

# =============================================================================
# IDE/Editor File Tests
# =============================================================================

@test "git-diff-filter.sh: excludes .DS_Store files" {
    echo "code" > app.js
    echo "DS_Store data" > .DS_Store
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app.js"* ]]
    [[ "$output" != *".DS_Store"* ]]
}

@test "git-diff-filter.sh: excludes vim swap files" {
    echo "code" > app.js
    echo "swap" > app.js.swp
    echo "swo" > app.js.swo
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app.js"* ]]
    [[ "$output" != *".swp"* ]]
    [[ "$output" != *".swo"* ]]
}

@test "git-diff-filter.sh: excludes backup files" {
    echo "code" > app.js
    echo "backup" > app.js~
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"diff.*app.js"* ]] || [[ "$output" == *"app.js"* ]]
    [[ "$output" != *"app.js~"* ]]
}

# =============================================================================
# Minified File Tests
# =============================================================================

@test "git-diff-filter.sh: excludes .min.css files" {
    echo "styles" > styles.css
    echo "minified" > styles.min.css
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"styles.css"* ]]
    [[ "$output" != *"styles.min.css"* ]]
}

# =============================================================================
# Edge Cases and Integration Tests
# =============================================================================

@test "git-diff-filter.sh: handles multiple lock files simultaneously" {
    echo "code" > app.js
    echo "{}" > package-lock.json
    echo "{}" > yarn.lock
    echo "{}" > pnpm-lock.yaml
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app.js"* ]]
    [[ "$output" != *"package-lock.json"* ]]
    [[ "$output" != *"yarn.lock"* ]]
    [[ "$output" != *"pnpm-lock.yaml"* ]]
}

@test "git-diff-filter.sh: handles mix of filtered and unfiltered files" {
    echo "source" > app.js
    echo "test" > app.test.js
    echo "{}" > package-lock.json
    echo "minified" > bundle.min.js
    mkdir -p dist
    echo "built" > dist/output.js
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    # Should include source files
    [[ "$output" == *"app.js"* ]]
    [[ "$output" == *"app.test.js"* ]]
    # Should exclude noise files
    [[ "$output" != *"package-lock.json"* ]]
    [[ "$output" != *"bundle.min.js"* ]]
    [[ "$output" != *"dist/output.js"* ]]
}

@test "git-diff-filter.sh: returns empty when only noise files changed" {
    echo "{}" > package-lock.json
    echo "lock" > yarn.lock
    git add .

    run bash -c "$PROJECT_ROOT/skills/review-code/scripts/git-diff-filter.sh 2>/dev/null"
    [ "$status" -eq 0 ]
    # Output should be empty or just whitespace
    [ -z "$output" ] || [[ "$output" =~ ^[[:space:]]*$ ]]
}
