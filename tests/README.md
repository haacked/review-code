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
├── integration/        # End-to-end workflow tests
├── fixtures/           # Test data (diffs, PR data, review files)
│   ├── diffs/
│   ├── files/
│   ├── pr-data/
│   └── reviews/
└── helpers/            # Shared test utilities
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

## Known Issues

- Empty diffs produce arrays with one empty string instead of empty arrays

## Contributing

When adding new scripts:

1. Create corresponding test file in `tests/unit/`
2. Write tests for happy path, edge cases, and error conditions
3. Ensure `bin/test` passes before committing
