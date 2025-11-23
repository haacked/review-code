# Review-Code for Claude Code

[![CI](https://github.com/haacked/review-code/actions/workflows/ci.yml/badge.svg)](https://github.com/haacked/review-code/actions/workflows/ci.yml)

A comprehensive code review system for Claude Code that uses specialized AI agents to review your code for security, performance, maintainability, testing, compatibility, and architecture concerns.

> **⚠️ macOS Users:** This tool requires **bash 4.0+**. macOS ships with bash 3.2 by default. Install bash 4.0+ with `brew install bash` before proceeding.

## Goals

This system was built with three core objectives:

### 1. Comprehensive Code Reviews

Seven specialized agents each focus on a distinct aspect of code quality, ensuring nothing falls through the cracks:

**Core Agents (Always Run):**
- **Security**: Vulnerabilities, OWASP Top 10, secret management
- **Performance**: Database optimization, N+1 queries, algorithmic complexity
- **Maintainability**: Code clarity, simplicity, technical debt
- **Testing**: Coverage, quality, edge cases
- **Compatibility**: Breaking changes, backward compatibility
- **Architecture**: System design, patterns, necessity

**Domain-Specific Agents (Conditional):**
- **Frontend**: React, Kea state management, accessibility, hooks (runs only for .tsx/.jsx files)

Each agent runs independently and in parallel, providing deep expertise in its domain rather than a superficial scan across all concerns.

#### Why Multiple Specialized Agents?

This architecture solves real problems encountered with single-agent reviews:

**Problem with Single Agent Approach:**
- Required multiple review passes, manually asking to focus on different aspects each time
- Sequential execution through a long checklist meant slow reviews (12-18s)
- Context window filled up by the time later checklist items were reached, degrading quality
- Superficial coverage across all concerns since one agent can't be expert in everything

**Benefits of Multiple Specialized Agents:**
- **Parallel Execution**: 6 agents × 2-3s = 3-4s total (4-6x faster than sequential)
- **Fresh Context Windows**: Each agent gets full context budget, maintaining quality across all areas
- **Deep Expertise**: Security agent knows OWASP Top 10, performance agent knows N+1 patterns
- **Token Efficiency**: Each agent loads only relevant context (security doesn't need performance guidelines)
- **Focused Findings**: Specialized agents provide more actionable, detailed recommendations

This isn't premature abstraction - it's solving proven problems with a domain-appropriate architecture.

### 2. Token Efficiency

Review-code achieves 40-60% token savings through multiple optimization strategies:

- **Diff Compression**: Minimal context lines (1 vs 3) - agents can read full files when needed
- **Smart Context Loading**: Only loads guidelines for detected languages/frameworks
- **Architectural Context Caching**: Caches context exploration results for 24 hours
- **Incremental Diff Tracking**: Only reviews files changed since last review
- **Bash Scripts for Heavy Lifting**: Uses shell scripts for diff generation, file detection, and context preparation instead of consuming tokens

This means you get thorough reviews without burning through your token budget.

### 3. Continuous Improvement via Feedback Loop

The system learns and improves over time through a structured feedback mechanism:

- **Structured Context Files**: Language, framework, org, and repo-specific guidelines live in `context/` directories
- **Review Artifacts**: Every review is saved with confidence scores and detailed findings
- **Iterative Refinement**: Insights from reviews can be fed back into context files to improve future reviews
- **Agent Specialization**: Findings help refine each agent's focus areas and detection patterns
- **Knowledge Accumulation**: Org and repo contexts capture institutional knowledge about patterns, antipatterns, and conventions

This creates a virtuous cycle where reviews get better as you identify new patterns to detect or guidelines to enforce.

## Features

- **7 Specialized Review Agents**: Each agent focuses on a specific aspect of code quality
  - **Core Agents (6)**: Security, Performance, Maintainability, Testing, Compatibility, Architecture
  - **Domain-Specific (1)**: Frontend (conditional - runs only for React/TypeScript files)
- **Hierarchical Context Loading**: Automatically loads language, framework, org, and repo-specific guidelines
- **PR and Local Review Modes**: Review pull requests or uncommitted changes
- **Token Optimizations**: Diff filtering (excludes lock files, snapshots, generated code), context caching (40-60% savings)
- **Confidence Scoring**: Every finding includes confidence level (20-100%) to help prioritize
- **Context Explorer**: Pre-review agent gathers architectural context before specialized reviews

## Quick Start

### Prerequisites

Before installing, ensure you have:

- **bash 4.0+**: `bash --version`
  - **macOS users MUST install bash 4.0+**: `brew install bash` (system bash 3.2 will NOT work)
  - **Why:** The system uses bash 4.0+ features (associative arrays, case conversion operators)
  - **Verify:** Run `bash --version` - should show 4.0 or higher
- **git**: `git --version` (install from [git-scm.com](https://git-scm.com))
- **gh (GitHub CLI)**: `gh --version` (install from [cli.github.com](https://cli.github.com))
- **jq**: `jq --version` (`brew install jq`)
- **Claude Code**: The `~/.claude` directory should exist

### Installation

#### Option 1: Quick Install (Recommended)

Install with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/haacked/review-code/main/install.sh | bash
```

This will:

- Download review-code temporarily
- Install files to `~/.claude/` and your chosen review directory
- Clean up the download automatically
- No repository kept around after installation

#### Option 2: Local Development Install

For developers working on review-code:

1. Clone this repository:

```bash
git clone https://github.com/haacked/review-code ~/dev/haacked/review-code
```

2. Run the setup script:

```bash
cd ~/dev/haacked/review-code
bin/setup
```

3. Run tests to verify everything works:

```bash
bin/test
```

4. Make changes and re-run setup to test:

```bash
# Edit agents, scripts, or context files
vim agents/code-reviewer-security.md

# Run tests to ensure changes work
bin/test

# Re-install to test changes
bin/setup
```

Both methods will:

- Copy files to `~/.claude/commands/`, `~/.claude/agents/`, and `~/.claude/bin/`
- Copy context files to your review directory (user-editable)
- Prompt you to choose where to save code reviews (default: `~/dev/ai/reviews`)
- Show permissions guide for Claude Code

## Usage

### Review Local Changes

```bash
/review-code
```

Smart mode that prompts you to choose:

- If on main/master: Reviews uncommitted changes only
- If on feature branch with uncommitted changes: Prompts to review uncommitted, branch, or both
- If on feature branch with no uncommitted changes: Reviews entire branch vs base

### Review Pull Requests

```bash
/review-code 123                                    # Review PR #123 from current repo
/review-code https://github.com/org/repo/pull/456  # Review PR by URL
```

### Review Git History

```bash
/review-code 356ded2                    # Review that specific commit
/review-code feature-branch             # Review entire branch vs main
/review-code abc123..HEAD               # Review changes from abc123 to HEAD
/review-code v1.0.0..v2.0.0            # Review changes between two tags
```

### Run Specific Review Type (on uncommitted changes)

```bash
/review-code security        # Security review only
/review-code performance     # Performance review only
/review-code maintainability # Maintainability review only
/review-code testing         # Testing review only
/review-code compatibility   # Compatibility review only
/review-code architecture    # Architecture review only
/review-code frontend        # Frontend review only (React/TypeScript)
```

### Filter by File Pattern

Add a file pattern as the second argument to review only matching files:

```bash
/review-code "*.sh"                     # Review only shell scripts (uncommitted)
/review-code 356ded2..HEAD "*.py"       # Review only Python files in range
/review-code feature-branch "src/**/*.ts" # Review only TypeScript in src/
/review-code 123 "lib/*.rs"            # Review only Rust files in lib/ for PR #123
/review-code security "*.go"           # Security review only Go files (uncommitted)
```

File patterns support:
- Wildcards: `*.js`, `*.{ts,tsx}`
- Directories: `src/**/*.py`
- Specific paths: `lib/auth.rs`

### How Review Determines What to Review

When you run `/review-code`, the system:

1. **Shows you a summary** of what will be reviewed before starting:
   ```
   📋 Review Summary

   Repository: posthog/posthog
   Branch: feature-branch (vs master)
   Location: /path/to/worktree
   Comparison: master..feature-branch

   Changes:
   - Commits: 3
   - Files: 12
   - Added: +450 lines
   - Removed: -123 lines
   ```

2. **Asks for confirmation** before running the review agents

3. **Determines the base branch** using smart detection:
   - Gets default branch name from `git symbolic-ref refs/remotes/origin/HEAD` (e.g., "master" or "main")
   - **Prefers local branch**: If `master` exists locally, compares against local `master`
   - **Falls back to remote**: If local doesn't exist, uses `origin/master`
   - **Fallback chain**: Tries `main` → `origin/main` → `master` → `origin/master` if origin/HEAD doesn't exist

   This means:
   - **Fresh clones work**: Even if you haven't checked out main/master locally
   - **Clearer comparisons**: Summary shows whether comparing against local or remote branch
   - **Accurate commit counts**: Shows exactly how many commits will be reviewed

4. **Counts commits in the range**: For branch reviews, shows commit count from base to HEAD

This eliminates confusion about what's being reviewed and lets you cancel if the wrong files or range were detected.

## Review Agents

The system includes 7 specialized agents organized into core (always run) and domain-specific (conditional) categories.

### Security (`code-reviewer-security`)

Focuses on:

- Authentication and authorization vulnerabilities
- Input validation and sanitization
- SQL injection, XSS, CSRF protection
- Secret management
- API security
- OWASP Top 10 compliance

### Performance (`code-reviewer-performance`)

Focuses on:

- Database query optimization
- N+1 query detection
- Caching opportunities
- Algorithmic complexity
- Memory leaks
- Resource usage

### Maintainability (`code-reviewer-maintainability`)

Focuses on:

- Code clarity and readability
- Function/class complexity
- Naming conventions
- Code duplication
- Technical debt
- Simplicity (YAGNI, KISS)

### Testing (`code-reviewer-testing`)

Focuses on:

- Test coverage adequacy
- Test quality and clarity
- Missing edge cases
- Test maintainability
- Flaky tests
- Test naming

### Compatibility (`code-reviewer-compatibility`)

Focuses on:

- Breaking API changes
- Database migration safety
- Backward compatibility
- Versioning concerns
- Deprecation handling

### Architecture (`code-reviewer-architecture`)

Focuses on:

- System design appropriateness
- Component boundaries
- Coupling and cohesion
- Abstraction levels
- Pattern misuse
- Over-engineering
- Necessity (YAGNI)
- Code reuse opportunities

### Frontend (`code-reviewer-frontend`) **[Conditional]**

**Runs only when:** `.tsx`, `.jsx`, or frontend-related files are detected in the diff

Focuses on:

- React component design and patterns
- Kea/Redux state management
- Hooks usage and dependencies
- Accessibility (a11y) compliance
- React performance (re-renders, memoization)
- TypeScript type safety for components
- Component lifecycle and side effects

**Why conditional?** Frontend expertise is only needed for React/TypeScript changes. Running it unconditionally wastes tokens on backend-only changes.

## Context System

Review-code automatically loads context based on your code:

### Language Context

Detects languages in your changes and loads language-specific guidelines:

- Python, TypeScript, Rust, SQL, Bash, Go, Ruby, Elixir, C#, Java, PHP, Swift, Kotlin, Dart

### Framework Context

Detects frameworks and loads framework-specific patterns:

- Django, React, Kea, Node.js, ASP.NET Core, Flutter, React Native, iOS, Android

### Organization Context

If your repo belongs to a known organization, loads org-specific patterns. You can add your own organization context in `context/orgs/{org-name}/org.md`.

See [Customization Guide](docs/custom-org-context.md) for details.

### Repository Context

Loads repo-specific workflows and requirements. Add your own in `context/orgs/{org-name}/repos/{repo-name}.md`.

## Configuration

### Review Output Path

Reviews are saved to a configurable location. The default is `~/dev/ai/reviews/{org}/{repo}/{pr-number-or-branch}.md`.

To change the path, edit `~/.claude/review-code.env`:

```bash
REVIEW_ROOT_PATH="$HOME/my-custom-path/reviews"
```

The directory structure will be created automatically:

```text
~/my-custom-path/reviews/
├── org-name/
│   ├── repo-name/
│   │   ├── pr-123.md
│   │   ├── pr-456.md
│   │   └── feature-branch.md
```

## Testing

The review-code shell scripts have automated test coverage using [BATS](https://github.com/bats-core/bats-core).

**Run all tests:**

```bash
bin/test
```

**Run specific test file:**

```bash
bats tests/unit/test-pre-review-context.bats
```

**Current test coverage:**

- ✅ `pre-review-context.sh` - 12 tests (file metadata extraction)
- ✅ `code-language-detect.sh` - 18 tests (language/framework detection)
- ⏳ Additional scripts - TODO (see `tests/README.md`)

See [`tests/README.md`](tests/README.md) for detailed testing documentation.

## Token Optimizations

The review system includes several optimizations to reduce token usage by 40-60%:

1. **Diff Compression**: Uses minimal context lines (1 instead of 3) - agents can read full files if needed
2. **Smart Context Loading**: Only loads context for detected languages/frameworks
3. **Bash Heavy Lifting**: Shell scripts handle diff generation, parsing, and context gathering

**Environment Variables:**

- `DIFF_CONTEXT_LINES` - Override diff context lines (default: 1)

## Output Format

Reviews are saved as structured Markdown with:

- Summary of findings by severity
- Confidence scores for each finding (20-100%)
- Detailed findings with file locations
- Code snippets showing issues
- Specific recommendations
- Links to relevant documentation

Example:

```markdown
# Code Review: PR #123

## Summary

🔴 **2 Critical Issues**
🟡 **5 Moderate Issues**
🟢 **3 Minor Improvements**

## Security Review

### 🔴 Critical: SQL Injection Vulnerability [95% confidence]

**Location**: auth.py:45
**Issue**: User input directly interpolated into SQL query
...
```

## Uninstallation

To remove review-code:

```bash
~/.claude/bin/uninstall-review-code.sh
```

Or if you have the repo cloned:

```bash
cd ~/dev/haacked/review-code
./uninstall.sh
```

This removes:

- Command and agent files from `~/.claude/`
- Helper scripts from `~/.claude/bin/`
- Optionally removes context files and config (you'll be asked)
- Optionally removes old `~/.review-code/` directory if found

Your review files are preserved unless you explicitly choose to remove the context directory.

## Troubleshooting

### "Command not found" errors

- Ensure gh CLI is installed: `brew install gh`
- Ensure jq is installed: `brew install jq`
- Run the installer again to verify setup

### "Missing helper scripts" error

- Ensure you've cloned the full repository
- Check that `bin/` directory contains the helper scripts

### Reviews not loading org-specific context

- Check that org name matches directory: `context/orgs/{org-name}/`
- Org names are case-insensitive and normalized to lowercase

### Config file not being read

- Check file exists: `ls -la ~/.claude/review-code.env`
- Check syntax: `cat ~/.claude/review-code.env`
- Ensure `REVIEW_ROOT_PATH` is set correctly

## Documentation

- **[Customization Guide](docs/custom-org-context.md)** - Add your own org/repo context
- **[Standalone Installation Guide](docs/review-code-standalone.md)** - Detailed installation instructions
- **[DEBUG Mode Guide](docs/DEBUG.md)** - Debug and verify review processing

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

### Adding Context

The most valuable contributions are adding language, framework, and organization-specific context:

- Language context: `context/languages/{language}.md`
- Framework context: `context/frameworks/{framework}.md`
- Organization context: `context/orgs/{org-name}/org.md`

See the [Customization Guide](docs/custom-org-context.md) for details.

## License

MIT License - see [LICENSE.md](LICENSE.md) for details.

## Author

Phil Haack ([@haacked](https://github.com/haacked))
