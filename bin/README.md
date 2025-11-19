# Development Scripts

This directory contains development scripts for working **on** the review-code
repository itself.

## Scripts

### bin/setup

Sets up the project for local development. Runs the local installer to make
`/review-code` available in Claude Code.

```bash
bin/setup
```

### bin/fmt

Formats all shell scripts using `shfmt`.

```bash
# Format all scripts
bin/fmt

# Check formatting without changes
bin/fmt --check
```

Requirements: `shfmt` (install: `brew install shfmt`)

### bin/lint

Lints shell scripts using `shellcheck`.

```bash
bin/lint
```

Requirements: `shellcheck` (install: `brew install shellcheck`)

## Directory Structure

```text
review-code/
├── bin/              # Development scripts (this directory)
│   ├── setup         # Install review-code locally
│   ├── fmt           # Format shell scripts
│   ├── lint          # Lint shell scripts
│   └── helpers/      # Shared utilities for bin/ scripts
└── lib/              # Runtime scripts (installed to ~/.claude/bin/)
    ├── *.sh          # Helper scripts used by /review-code
    └── helpers/      # Shared utilities for lib/ scripts
```

## Usage Pattern

When working on review-code:

1. **First time setup**: `bin/setup`
2. **Make changes**: Edit files in lib/, agents/, commands/, etc.
3. **Format**: `bin/fmt`
4. **Lint**: `bin/lint`
5. **Test**: Run `bin/setup` again to reinstall locally
6. **Commit**: Commit your changes

The `bin/` scripts help maintain code quality, while `lib/` contains the actual
runtime scripts that get installed to the user's system.
