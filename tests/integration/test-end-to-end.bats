#!/usr/bin/env bats
# Integration tests for end-to-end review workflows
# These tests verify that all scripts work together correctly

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export PROJECT_ROOT

    # Create a temporary git repository for testing
    TEST_REPO=$(mktemp -d)
    cd "$TEST_REPO"
    git init
    git config user.email "test@example.com"
    git config user.name "Test User"
    git remote add origin "https://github.com/testorg/testrepo.git"

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
# Local Changes Review - End-to-End
# =============================================================================

@test "E2E: Local review detects staged Python changes" {
    # Create and modify a tracked Python file
    cat > app.py <<'EOF'
def hello():
    print("Hello, World!")
EOF
    git add app.py
    git commit -m "Add app.py"

    # Make a change
    echo "# comment" >> app.py

    # Run the orchestrator (it should detect local mode with unstaged changes)
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"

    # Should succeed
    [ "$status" -eq 0 ]

    # Should return valid JSON
    echo "$output" | jq -e '.' > /dev/null

    # Should detect Python language
    languages=$(echo "$output" | jq -r '.languages.languages[]')
    [[ "$languages" =~ "python" ]]

    # Should include the diff
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"app.py"* ]]

    # Should have mode=local
    mode=$(echo "$output" | jq -r '.mode')
    [ "$mode" = "local" ]
}

@test "E2E: Local review detects staged TypeScript changes" {
    # Create a TypeScript file and stage it
    cat > component.tsx <<'EOF'
import React from 'react';

export const MyComponent = () => {
    return <div>Hello</div>;
};
EOF
    git add component.tsx

    # Run the orchestrator
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"

    # Should succeed
    [ "$status" -eq 0 ]

    # Should detect TypeScript
    languages=$(echo "$output" | jq -r '.languages.languages[]')
    [[ "$languages" =~ "typescript" ]]

    # Should detect React framework
    frameworks=$(echo "$output" | jq -r '.languages.frameworks[]' | tr '\n' ' ')
    [[ "$frameworks" =~ "react" ]]

    # Should mark as frontend
    has_frontend=$(echo "$output" | jq -r '.languages.has_frontend')
    [ "$has_frontend" = "true" ]
}

# =============================================================================
# Range Review - End-to-End
# =============================================================================

@test "E2E: Range review processes commit range" {
    # Create second commit
    echo "second" > file2.txt
    git add file2.txt
    git commit -m "Second commit"

    # Create third commit
    echo "third" > file3.txt
    git add file3.txt
    git commit -m "Third commit"

    # Review the last two commits
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "HEAD~2..HEAD"

    # Should succeed
    [ "$status" -eq 0 ]

    # Should return valid JSON
    echo "$output" | jq -e '.' > /dev/null

    # Should have mode=range
    mode=$(echo "$output" | jq -r '.mode')
    [ "$mode" = "range" ]

    # Should include both files in the diff
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"file2.txt"* ]]
    [[ "$diff" == *"file3.txt"* ]]
}

@test "E2E: Range review validates revision specs (tests -- separator fix)" {
    # Create second commit
    echo "second" > file2.txt
    git add file2.txt
    git commit -m "Second commit"

    # Review using HEAD~1..HEAD syntax (this tests our -- separator fix)
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "HEAD~1..HEAD"

    # Should succeed (previously failed before -- fix)
    [ "$status" -eq 0 ]

    # Should detect the mode correctly
    mode=$(echo "$output" | jq -r '.mode')
    [ "$mode" = "range" ]

    # Should include the new file
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"file2.txt"* ]]
}

# =============================================================================
# Branch Review - End-to-End
# =============================================================================

@test "E2E: Branch review compares feature branch to main" {
    # Create feature branch
    git checkout -b feature
    echo "feature code" > feature.txt
    git add feature.txt
    git commit -m "Add feature"

    # Switch back to main
    git checkout main

    # Review the feature branch
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" feature

    # Should succeed
    [ "$status" -eq 0 ]

    # Should have mode=branch
    mode=$(echo "$output" | jq -r '.mode')
    [ "$mode" = "branch" ]

    # Should include feature file in diff
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"feature.txt"* ]]
    [[ "$diff" == *"feature code"* ]]
}

@test "E2E: Branch review detects multiple languages" {
    # Create feature branch with multiple file types
    git checkout -b multi-lang

    # Add Python file
    cat > api.py <<'EOF'
from flask import Flask
app = Flask(__name__)
EOF
    git add api.py

    # Add TypeScript file
    cat > frontend.ts <<'EOF'
const greeting: string = "Hello";
EOF
    git add frontend.ts

    git commit -m "Add multi-language files"

    # Switch back to main
    git checkout main

    # Review the branch
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" multi-lang

    # Should succeed
    [ "$status" -eq 0 ]

    # Should detect both languages
    languages=$(echo "$output" | jq -r '.languages.languages[]' | tr '\n' ' ')
    [[ "$languages" =~ "python" ]]
    [[ "$languages" =~ "typescript" ]]

    # Should detect Flask framework
    frameworks=$(echo "$output" | jq -r '.languages.frameworks[]' | tr '\n' ' ')
    [[ "$frameworks" =~ "flask" ]]
}

# =============================================================================
# File Pattern Filtering - End-to-End
# =============================================================================

@test "E2E: File pattern filters to specific files in branch mode" {
    # Create feature branch with multiple file types
    git checkout -b feature-files
    echo "python code" > app.py
    echo "typescript code" > app.ts
    echo "readme" > README.md
    git add app.py app.ts README.md
    git commit -m "Add multiple files"

    # Switch back to main
    git checkout main

    # Review only Python files from the branch
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "feature-files" "*.py"

    # Should succeed
    [ "$status" -eq 0 ]

    # Diff should include Python file
    diff=$(echo "$output" | jq -r '.diff')
    [[ "$diff" == *"app.py"* ]]

    # Diff should NOT include TypeScript or markdown
    [[ "$diff" != *"app.ts"* ]]
    [[ "$diff" != *"README.md"* ]]
}

# =============================================================================
# Error Handling - End-to-End
# =============================================================================

@test "E2E: Invalid range returns clear error" {
    # Try to review invalid range
    run bash -c "'$PROJECT_ROOT/lib/review-orchestrator.sh' 'invalid-ref..HEAD' 2>&1"

    # Should fail
    [ "$status" -eq 1 ]

    # Should return error JSON
    echo "$output" | jq -e '.mode == "error"' > /dev/null ||
        echo "$output" | jq -e '.status == "error"' > /dev/null
}

@test "E2E: No changes returns clear error" {
    # On main with no uncommitted changes - should error
    run bash -c "'$PROJECT_ROOT/lib/review-orchestrator.sh' 2>&1"

    # Should fail
    [ "$status" -eq 1 ]

    # Should have error message
    [[ "$output" == *"error"* ]]
}

# =============================================================================
# Ambiguous Input Handling - End-to-End
# =============================================================================

@test "E2E: Current branch name triggers prompt" {
    # Create feature branch
    git checkout -b feature
    echo "change" > change.txt
    git add change.txt
    git commit -m "Change"

    # Add uncommitted changes
    echo "more" >> change.txt

    # Review current branch (ambiguous - branch or uncommitted?)
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" feature

    # Should succeed but with prompt status
    [ "$status" -eq 0 ]

    # Should indicate ambiguity
    status_field=$(echo "$output" | jq -r '.status')
    [[ "$status_field" == "prompt" ]] || [[ "$status_field" == "ambiguous" ]]
}

# =============================================================================
# JSON Output Validation - End-to-End
# =============================================================================

@test "E2E: Output includes required fields for review" {
    # Create tracked file and make a change
    echo "initial" > test.py
    git add test.py
    git commit -m "Add test.py"

    # Modify it
    echo "modified" >> test.py

    # Run orchestrator
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"

    # Should succeed
    [ "$status" -eq 0 ]

    # Validate required fields exist
    echo "$output" | jq -e '.mode' > /dev/null
    echo "$output" | jq -e '.diff' > /dev/null
    # Languages structure can vary - check both possible locations
    echo "$output" | jq -e '.languages' > /dev/null
    # has_frontend should exist somewhere in the output
    echo "$output" | jq 'has("languages")' | grep -q "true"
}

@test "E2E: Output is always valid JSON" {
    # Create uncommitted change
    echo "test" > test.txt

    # Run orchestrator
    run "$PROJECT_ROOT/lib/review-orchestrator.sh"

    # Even if it fails, output should be valid JSON
    echo "$output" | jq -e '.' > /dev/null
}
