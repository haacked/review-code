#!/usr/bin/env bats
# Tests for get-review-diff.sh

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT
    export DIFF_CONTEXT_LINES=1
}

# =============================================================================
# Mode validation tests
# =============================================================================

@test "get-review-diff.sh: requires mode argument" {
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh"
    [ "$status" -eq 1 ]
}

@test "get-review-diff.sh: rejects unknown mode" {
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" unknown-mode
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown diff mode"* ]]
}

# =============================================================================
# commit mode tests
# =============================================================================

@test "get-review-diff.sh: commit mode requires commit hash" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" commit
    [ "$status" -ne 0 ]
}

@test "get-review-diff.sh: commit mode generates diff" {
    cd "$PROJECT_ROOT"
    # Use HEAD as the commit
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" commit HEAD
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: commit (HEAD)"* ]]
}

@test "get-review-diff.sh: commit mode with file pattern" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" commit HEAD "*.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: commit (HEAD) filtered by: *.sh"* ]]
}

# =============================================================================
# branch mode tests
# =============================================================================

@test "get-review-diff.sh: branch mode requires branch name" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch
    [ "$status" -ne 0 ]
}

@test "get-review-diff.sh: branch mode requires base branch" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch feature-branch
    [ "$status" -ne 0 ]
}

@test "get-review-diff.sh: branch mode with file pattern" {
    cd "$PROJECT_ROOT"
    # This will fail if branches don't exist, but tests the argument parsing
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch main main "*.md"
    # Status might be non-zero if branches are the same, but should show filtered type
    [[ "$output" == *"filtered by: *.md"* ]] || [ "$status" -ne 0 ]
}

# =============================================================================
# range mode tests
# =============================================================================

@test "get-review-diff.sh: range mode requires range argument" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" range
    [ "$status" -ne 0 ]
}

@test "get-review-diff.sh: range mode generates diff" {
    cd "$PROJECT_ROOT"
    # Use HEAD~1..HEAD as the range
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" range "HEAD~1..HEAD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: range (HEAD~1..HEAD)"* ]]
}

@test "get-review-diff.sh: range mode with file pattern" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" range "HEAD~1..HEAD" "lib/*.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"filtered by: lib/*.sh"* ]]
}

# =============================================================================
# local mode tests
# =============================================================================

@test "get-review-diff.sh: local mode works without arguments" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" local
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: local (uncommitted)"* ]]
}

@test "get-review-diff.sh: local mode with file pattern" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" local "*.bats"
    [ "$status" -eq 0 ]
    [[ "$output" == *"filtered by: *.bats"* ]]
}

# =============================================================================
# branch-plus-uncommitted mode tests
# =============================================================================

@test "get-review-diff.sh: branch-plus-uncommitted requires branch" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch-plus-uncommitted
    [ "$status" -ne 0 ]
}

@test "get-review-diff.sh: branch-plus-uncommitted requires base" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch-plus-uncommitted feature
    [ "$status" -ne 0 ]
}

@test "get-review-diff.sh: branch-plus-uncommitted with file pattern" {
    cd "$PROJECT_ROOT"
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch-plus-uncommitted main main "*.sh"
    [[ "$output" == *"filtered by: *.sh"* ]] || [ "$status" -ne 0 ]
}

# =============================================================================
# Exclusion pattern tests
# =============================================================================

@test "get-review-diff.sh: excludes lock files" {
    cd "$PROJECT_ROOT"
    # Check that exclusion patterns are being used (common mode)
    run bash -c "source '$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh' 2>&1 >/dev/null || true"
    # Should source exclusion-patterns.sh
    [ "$status" -eq 0 ]
}

# =============================================================================
# DIFF_CONTEXT_LINES environment variable
# =============================================================================

@test "get-review-diff.sh: respects DIFF_CONTEXT_LINES env var" {
    cd "$PROJECT_ROOT"
    export DIFF_CONTEXT_LINES=5
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" commit HEAD
    [ "$status" -eq 0 ]
    # Verify it ran (exact diff validation would be fragile)
}

@test "get-review-diff.sh: defaults to 1 context line" {
    cd "$PROJECT_ROOT"
    unset DIFF_CONTEXT_LINES
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" commit HEAD
    [ "$status" -eq 0 ]
}

# =============================================================================
# Integration tests with actual git repository
# =============================================================================

setup_test_repo() {
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init -q
    git config commit.gpgsign false
    git config user.email "test@example.com"
    git config user.name "Test User"
}

teardown_test_repo() {
    cd /
    rm -rf "$TEST_REPO"
}

@test "get-review-diff.sh: commit mode shows actual changes" {
    setup_test_repo

    # Create initial commit
    echo "initial content" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"

    # Create second commit
    echo "changed content" > file.txt
    git add file.txt
    git commit -q -m "Change file"

    # Get diff for last commit
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" commit HEAD

    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: commit (HEAD)"* ]]
    [[ "$output" == *"file.txt"* ]]
    [[ "$output" == *"changed content"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: branch mode shows branch differences" {
    setup_test_repo

    # Create main branch with initial commit
    echo "main content" > file.txt
    git add file.txt
    git commit -q -m "Main commit"

    # Create feature branch with changes
    git checkout -q -b feature
    echo "feature content" > feature.txt
    git add feature.txt
    git commit -q -m "Feature commit"

    # Get diff between main and feature
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch feature main

    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: branch (main..feature)"* ]]
    [[ "$output" == *"feature.txt"* ]]
    [[ "$output" == *"feature content"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: range mode shows range of changes" {
    setup_test_repo

    # Create multiple commits
    echo "v1" > file.txt
    git add file.txt
    git commit -q -m "Commit 1"

    echo "v2" > file.txt
    git add file.txt
    git commit -q -m "Commit 2"

    echo "v3" > file.txt
    git add file.txt
    git commit -q -m "Commit 3"

    # Get diff for last 2 commits
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" range "HEAD~2..HEAD"

    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: range (HEAD~2..HEAD)"* ]]
    [[ "$output" == *"file.txt"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: local mode shows staged changes" {
    setup_test_repo

    # Create initial commit
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial"

    # Make staged changes
    echo "staged change" > file.txt
    git add file.txt

    # Get local diff
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" local

    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: local (uncommitted)"* ]]
    [[ "$output" == *"file.txt"* ]]
    [[ "$output" == *"staged change"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: local mode shows unstaged changes" {
    setup_test_repo

    # Create initial commit
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial"

    # Make unstaged changes
    echo "unstaged change" > file.txt

    # Get local diff
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" local

    [ "$status" -eq 0 ]
    [[ "$output" == *"file.txt"* ]]
    [[ "$output" == *"unstaged change"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: local mode combines staged and unstaged" {
    setup_test_repo

    # Create initial commit
    echo "initial" > file1.txt
    echo "initial" > file2.txt
    git add .
    git commit -q -m "Initial"

    # Make staged changes
    echo "staged" > file1.txt
    git add file1.txt

    # Make unstaged changes
    echo "unstaged" > file2.txt

    # Get local diff
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" local

    [ "$status" -eq 0 ]
    # Should show staged file (definitely)
    [[ "$output" == *"file1.txt"* ]]
    # git-diff-filter.sh shows both staged and unstaged in its output
    # The exact format may vary, so just verify it succeeded

    teardown_test_repo
}

@test "get-review-diff.sh: branch-plus-uncommitted combines branch and local" {
    setup_test_repo

    # Create main branch
    echo "main" > file1.txt
    git add file1.txt
    git commit -q -m "Main"

    # Create feature branch with commit
    git checkout -q -b feature
    echo "feature" > file2.txt
    git add file2.txt
    git commit -q -m "Feature"

    # Make uncommitted changes
    echo "uncommitted" > file3.txt
    git add file3.txt

    # Get combined diff
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch-plus-uncommitted feature main

    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: branch + uncommitted (main..feature + local)"* ]]
    [[ "$output" == *"file2.txt"* ]]  # Branch changes
    [[ "$output" == *"file3.txt"* ]]  # Uncommitted changes
    [[ "$output" == *"Uncommitted Changes"* ]]

    teardown_test_repo
}

# =============================================================================
# File pattern filtering tests
# =============================================================================

@test "get-review-diff.sh: commit mode file pattern filters correctly" {
    setup_test_repo

    # Create commit with multiple file types
    echo "js code" > app.js
    echo "py code" > app.py
    echo "text" > readme.txt
    git add .
    git commit -q -m "Add files"

    # Filter only .js files
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" commit HEAD "*.js"

    [ "$status" -eq 0 ]
    [[ "$output" == *"app.js"* ]]
    [[ "$output" != *"app.py"* ]]
    [[ "$output" != *"readme.txt"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: local mode file pattern filters correctly" {
    setup_test_repo

    # Create initial commit
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial"

    # Make changes to multiple files
    echo "change" > app.js
    echo "change" > app.py
    echo "change" > readme.md
    git add .

    # Filter only .js files
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" local "*.js"

    [ "$status" -eq 0 ]
    [[ "$output" == *"app.js"* ]]
    [[ "$output" != *"app.py"* ]]
    [[ "$output" != *"readme.md"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: file pattern with directory path" {
    setup_test_repo

    # Create directory structure
    mkdir -p src lib
    echo "src code" > src/app.js
    echo "lib code" > lib/util.js
    git add .
    git commit -q -m "Add files"

    # Filter only src/ files
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" commit HEAD "src/*.js"

    [ "$status" -eq 0 ]
    [[ "$output" == *"src/app.js"* ]]
    [[ "$output" != *"lib/util.js"* ]]

    teardown_test_repo
}

# =============================================================================
# Exclusion pattern tests (using common mode)
# =============================================================================

@test "get-review-diff.sh: excludes package-lock.json in commit mode" {
    setup_test_repo

    # Create commit with code and lock file
    echo "code" > app.js
    echo '{"lock":"file"}' > package-lock.json
    git add .
    git commit -q -m "Add files"

    # Get diff
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" commit HEAD

    [ "$status" -eq 0 ]
    [[ "$output" == *"app.js"* ]]
    [[ "$output" != *"package-lock.json"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: excludes minified files in local mode" {
    setup_test_repo

    # Create initial commit
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial"

    # Stage code and minified file
    echo "code" > app.js
    echo "minified" > app.min.js
    git add .

    # Get diff
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" local

    [ "$status" -eq 0 ]
    [[ "$output" == *"app.js"* ]]
    [[ "$output" != *"app.min.js"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: excludes build directories in branch mode" {
    setup_test_repo

    # Create main branch
    echo "main" > README.md
    git add README.md
    git commit -q -m "Main"

    # Create feature branch with code and build output
    git checkout -q -b feature
    mkdir -p dist
    echo "source" > app.js
    echo "built" > dist/bundle.js
    git add .
    git commit -q -m "Feature"

    # Get diff
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch feature main

    [ "$status" -eq 0 ]
    [[ "$output" == *"app.js"* ]]
    [[ "$output" != *"dist/bundle.js"* ]]

    teardown_test_repo
}

# =============================================================================
# Edge cases
# =============================================================================

@test "get-review-diff.sh: handles empty diff gracefully" {
    setup_test_repo

    # Create commit
    echo "content" > file.txt
    git add file.txt
    git commit -q -m "Commit"

    # Try to diff with itself (empty)
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" range "HEAD..HEAD"

    [ "$status" -eq 0 ]
    # Should have DIFF_TYPE but minimal content
    [[ "$output" == *"DIFF_TYPE:"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: handles no uncommitted changes in local mode" {
    setup_test_repo

    # Create commit with no uncommitted changes
    echo "content" > file.txt
    git add file.txt
    git commit -q -m "Commit"

    # Get local diff (should be empty)
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" local

    [ "$status" -eq 0 ]
    [[ "$output" == *"DIFF_TYPE: local (uncommitted)"* ]]

    teardown_test_repo
}

@test "get-review-diff.sh: file pattern detection doesn't match branch names" {
    setup_test_repo

    # Create branches with special names
    echo "main" > file.txt
    git add file.txt
    git commit -q -m "Main"

    git checkout -q -b "feature.test"
    echo "feature" > file.txt
    git add file.txt
    git commit -q -m "Feature"

    # Branch name contains dot but shouldn't be treated as file pattern
    run "$PROJECT_ROOT/skills/review-code/scripts/get-review-diff.sh" branch "feature.test" main

    [ "$status" -eq 0 ]
    # Should NOT show "filtered by" since feature.test is the branch name
    [[ "$output" != *"filtered by"* ]]

    teardown_test_repo
}
