# Test Fixtures

This directory contains test fixtures for the review-code test suite. Fixtures provide realistic test data for edge cases and scenarios that are difficult to generate dynamically.

## Directory Structure

```
fixtures/
├── diffs/          # Sample git diffs for various languages and scenarios
├── files/          # Edge case files (special chars, empty files, etc.)
├── pr-data/        # Mock GitHub PR data
└── README.md       # This file
```

## Available Fixtures

### Git Diffs (`diffs/`)

Sample diffs demonstrating various languages and frameworks:

#### `python-flask.diff`
- **Language**: Python
- **Framework**: Flask
- **Features**: REST API, SQLAlchemy models, database operations
- **Use Case**: Testing Python backend code detection
- **Lines**: 25 additions
- **Files**: 1 (api/app.py)

#### `typescript-react.diff`
- **Language**: TypeScript + React
- **Framework**: React with hooks
- **Features**: Component, async/await, error handling, TypeScript types
- **Use Case**: Testing frontend framework detection
- **Lines**: 45 additions
- **Files**: 1 (src/components/UserList.tsx)

#### `rust-web.diff`
- **Language**: Rust
- **Framework**: Actix-web, SQLx
- **Features**: Web handlers, async, database queries
- **Use Case**: Testing Rust web framework detection
- **Lines**: 38 additions (partial)
- **Files**: 1 (src/handlers.rs)

#### `large-changes.diff`
- **Type**: Lock file changes
- **Features**: Large number of lines changed (5000+)
- **Use Case**: Testing performance with large diffs
- **Files**: 1 (package-lock.json)

### Edge Case Files (`files/`)

Files for testing special character handling and edge cases:

#### `special-chars.txt`
- **Purpose**: Test Unicode, emoji, and special character handling
- **Contents**:
  - Unicode in multiple languages (Japanese, Chinese, Korean, Arabic, Hebrew)
  - Emoji characters
  - Special symbols
  - Escaped characters
  - Tabs and newlines
- **Use Case**: Ensure safe handling of non-ASCII characters

#### `empty-file.txt`
- **Purpose**: Test empty file handling
- **Contents**: (empty)
- **Use Case**: Edge case for file processing

### PR Data (`pr-data/`)

Mock GitHub PR data for testing PR review flows:

#### `pr-123.json`
- **Type**: Small/medium PR
- **Commits**: 5
- **Files Changed**: 8
- **Additions**: 245
- **Deletions**: 32
- **Use Case**: Testing typical PR review flow
- **Features**: JWT authentication feature

#### `pr-456-large.json`
- **Type**: Large refactoring PR
- **Commits**: 47
- **Files Changed**: 152
- **Additions**: 15,243
- **Deletions**: 8,932
- **Use Case**: Testing large PR handling
- **Features**: TypeScript migration

## Usage in Tests

### Loading Diff Fixtures

```bash
# In BATS tests
@test "Language detection handles Python/Flask" {
    diff_content=$(cat "$PROJECT_ROOT/tests/fixtures/diffs/python-flask.diff")
    result=$(echo "$diff_content" | "$PROJECT_ROOT/lib/code-language-detect.sh")

    # Should detect Python and Flask
    echo "$result" | jq -e '.languages[] | select(. == "python")' > /dev/null
    echo "$result" | jq -e '.frameworks[] | select(. == "flask")' > /dev/null
}
```

### Loading PR Data

```bash
# In BATS tests with mocked gh CLI
@test "PR review handles large PRs" {
    # Mock gh pr view to return fixture data
    gh() {
        if [[ "$1" == "pr" && "$2" == "view" ]]; then
            cat "$PROJECT_ROOT/tests/fixtures/pr-data/pr-456-large.json"
        fi
    }
    export -f gh

    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "456"
    [ "$status" -eq 0 ]
}
```

### Testing Special Characters

```bash
@test "File handling supports Unicode" {
    # Copy fixture to test repo
    cp "$PROJECT_ROOT/tests/fixtures/files/special-chars.txt" .
    git add special-chars.txt
    git commit -m "Add special chars"

    # Should handle without errors
    run "$PROJECT_ROOT/lib/review-orchestrator.sh" "HEAD~1..HEAD"
    [ "$status" -eq 0 ]
}
```

## Adding New Fixtures

When adding new fixtures:

1. **Place in appropriate directory**:
   - `diffs/` for git diff samples
   - `files/` for edge case files
   - `pr-data/` for GitHub PR JSON

2. **Use descriptive names**: `{language}-{framework}.diff` or `{type}-{scenario}.{ext}`

3. **Keep diffs realistic**: Use actual code patterns from real projects

4. **Document in this README**: Add entry describing:
   - Purpose/use case
   - Key features being tested
   - Language/framework
   - File count and line changes

5. **Keep fixtures small**: Unless testing large files specifically, keep fixtures under 100 lines

## Maintenance

Fixtures should be:
- **Realistic**: Based on actual code patterns
- **Minimal**: Only include what's needed to test the feature
- **Well-documented**: Clear purpose and usage
- **Version-controlled**: Never gitignore fixtures
- **Up-to-date**: Update when testing requirements change

## Best Practices

- **Don't use real secrets**: All data should be fake/sanitized
- **Test one thing**: Each fixture should focus on one scenario
- **Name clearly**: File names should indicate what they test
- **Keep it simple**: Avoid overly complex fixtures
- **Reuse when possible**: Check if an existing fixture works before creating a new one
