# Tests for review-code

This directory contains automated tests for the review-code shell scripts using [BATS (Bash Automated Testing System)](https://github.com/bats-core/bats-core).

## Running Tests

```bash
# Run all tests
bin/test

# Run specific test file
bats tests/unit/test-pre-review-context.bats

# Run tests in verbose mode
bats -t tests/unit/*.bats
```

## Test Organization

```
tests/
├── unit/               # Unit tests for individual scripts
│   ├── test-pre-review-context.bats
│   └── test-code-language-detect.bats
├── integration/        # Integration tests for workflows (TODO)
├── fixtures/          # Test data and sample files (TODO)
└── helpers/           # Shared test utilities (TODO)
```

## Writing Tests

Tests use BATS syntax:

```bash
@test "descriptive test name" {
    # Arrange
    input="test data"

    # Act
    result=$(echo "$input" | script.sh)

    # Assert
    echo "$result" | jq -e '.expected == "value"'
}
```

### Test Helpers

- Use `jq -e` for JSON assertions (exits 1 if assertion fails)
- Use `[ -x file ]` to check if file is executable
- Use `skip "reason"` to skip tests temporarily

## Test Coverage

Current coverage:

- ✅ `pre-review-context.sh` - 12 tests
- ✅ `code-language-detect.sh` - 18 tests
- ⏳ `incremental-diff.sh` - TODO
- ⏳ `parse-review-arg.sh` - TODO (priority: high)
- ⏳ `review-file-path.sh` - TODO (priority: high - security critical)
- ⏳ `review-orchestrator.sh` - TODO
- ⏳ Other lib scripts - TODO

## Installation

Install BATS:

```bash
# macOS
brew install bats-core

# Linux (Ubuntu/Debian)
sudo apt-get install bats

# Or install from source
git clone https://github.com/bats-core/bats-core.git
cd bats-core
./install.sh /usr/local
```

## CI Integration

Tests should be run automatically on every commit. Add to your git hooks:

```bash
# .git/hooks/pre-commit
#!/bin/bash
bin/test || exit 1
```

Or use GitHub Actions (see `.github/workflows/test.yml` if available).

## Known Issues

- `code-language-detect.sh` matches framework imports in comments (test skipped, needs fix)
- Empty diffs produce arrays with one empty string instead of empty arrays

## Contributing

When adding new scripts:
1. Create corresponding test file in `tests/unit/`
2. Write tests for happy path, edge cases, and error conditions
3. Ensure `bin/test` passes before committing
4. Aim for 80%+ coverage on critical scripts
