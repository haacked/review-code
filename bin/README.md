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

### bin/token-report

Measures review costs from Claude transcripts. Use prompt mode to locate large dispatches by date, agent, and transcript path:

```bash
bin/token-report --prompts --all-stages --since 2026-09-01 --limit 10
```

`--since` filters individual dispatch timestamps in prompt mode and excludes undated records. `--all-stages` includes context explorers, finding validators, and comprehension gates alongside the default `code-reviewer-*` agents. `--json` returns every matching row; `--limit` controls the largest-prompt table. Token estimates use characters divided by four, and payload detection is heuristic. See [the dispatch measurement](../docs/dispatch-prompt-measurement.md) for the current baseline and its limits.

## Directory Structure

```text
review-code/
├── bin/                          # Development scripts (this directory)
│   ├── setup                     # Install review-code locally
│   ├── fmt                       # Format shell scripts
│   ├── lint                      # Lint shell scripts
│   └── helpers/                  # Shared utilities for bin/ scripts
└── skills/review-code/scripts/   # Runtime scripts (installed with the skill)
    ├── *.sh                      # Helper scripts used by /review-code
    └── helpers/                  # Shared utilities for runtime scripts
```

## Usage Pattern

When working on review-code:

1. **First time setup**: `bin/setup`
2. **Make changes**: Edit files in skills/, agents/, etc.
3. **Format**: `bin/fmt`
4. **Lint**: `bin/lint`
5. **Test**: Run `bin/setup` again to reinstall locally
6. **Commit**: Commit your changes

The `bin/` scripts help maintain code quality, while
`skills/review-code/scripts/` contains the actual runtime scripts that get
installed to the user's system.
