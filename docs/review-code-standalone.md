# Review-Code for Claude Code

A comprehensive code review system for Claude Code that uses specialized AI agents to review your code for security, performance, maintainability, testing, compatibility, and architecture concerns.

## Features

- **6 Specialized Review Agents**: Each focuses on a specific aspect of code quality
- **Hierarchical Context Loading**: Automatically loads language, framework, org, and repo-specific guidelines
- **PR and Local Review Modes**: Review pull requests or uncommitted changes
- **Configurable Output Path**: Save reviews wherever you want
- **Standalone Installation**: Works independently from full dotfiles setup

## Quick Start

### Prerequisites

Before installing, ensure you have:

- **bash 4.0+**: `bash --version` (macOS: `brew install bash`)
- **git**: `git --version` (install from [git-scm.com](https://git-scm.com))
- **gh (GitHub CLI)**: `gh --version` (install from [cli.github.com](https://cli.github.com))
- **jq**: `jq --version` (`brew install jq`)
- **Claude Code**: The `~/.claude` directory should exist

### Installation

#### Option 1: Quick Install (Recommended)

Install with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/haacked/dotfiles/main/quick-install-review-code.sh | bash
```

This will:

- Download the necessary files from GitHub
- Run the installer
- Clean up automatically

#### Option 2: Manual Install

1. Clone this repository to `~/.dotfiles`:

```bash
git clone https://github.com/haacked/review-code ~/.dotfiles
```

1. Run the installer:

```bash
cd ~/.review-code
./install.sh
```

Both methods will:

- Prompt you to choose where to save code reviews (default: `~/dev/ai/reviews`)
- Complete installation in seconds

### Usage

#### Review Local Changes

```bash
/review-code
```

Reviews all uncommitted changes (staged and unstaged) with all 6 agents.

#### Review a Pull Request

```bash
/review-code 123              # Review PR #123 from current repo
/review-code https://github.com/org/repo/pull/456  # Review by URL
```

#### Run Specific Review Type

```bash
/review-code security        # Security review only
/review-code performance     # Performance review only
/review-code maintainability # Maintainability review only
/review-code testing         # Testing review only
/review-code compatibility   # Compatibility review only
/review-code architecture    # Architecture review only
```

## Review Agents

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

## Context System

Review-code automatically loads context based on your code:

### Language Context

Detects languages in your changes and loads language-specific guidelines:

- Python, TypeScript, Rust, SQL, Bash, Go, Ruby, Elixir, C#

### Framework Context

Detects frameworks and loads framework-specific patterns:

- Django, React, Kea (and more)

### Organization Context

If your repo belongs to a known organization, loads org-specific patterns:

- Infrastructure guidelines
- Security requirements
- Performance expectations
- UI/UX standards

### Repository Context

Loads repo-specific workflows and requirements:

- Testing requirements
- Code formatting standards
- Deployment procedures

## Configuration

### Review Output Path

Reviews are saved to a configurable location. The default is `~/dev/ai/reviews/{org}/{repo}/{pr-number-or-branch}.md`.

To change the path, edit `~/.claude/skills/review-code/.env`:

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

## Output Format

Reviews are saved as structured Markdown with:

- Summary of findings by severity
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

### 🔴 Critical: SQL Injection Vulnerability (auth.py:45)

**Issue**: User input directly interpolated into SQL query
...
```

## Uninstallation

To remove review-code:

```bash
./install.sh --uninstall
```

This removes:

- Symlinked command and agent files
- Optionally removes config file (you'll be asked)

Helper scripts and context files remain in `~/.dotfiles` for future use.

## Troubleshooting

### "Command not found" errors

- Ensure gh CLI is installed: `brew install gh`
- Ensure jq is installed: `brew install jq`
- Run the installer again to verify setup

### "Missing helper scripts" error

- Ensure you've cloned the full dotfiles repo
- Check that `~/.review-code/bin/` contains the helper scripts

### Reviews not loading org-specific context

- Check that org name matches directory: `~/.review-code/context/orgs/{org-name}/`
- Org names are case-insensitive and normalized to lowercase

### Config file not being read

- Check file exists: `ls -la ~/.claude/skills/review-code/.env`
- Check syntax: `cat ~/.claude/skills/review-code/.env`
- Ensure `REVIEW_ROOT_PATH` is set correctly

## Next Steps

- [Customization Guide](./custom-org-context.md) - Add your own org/repo context
- [Helper Scripts Reference](../bin/) - Understand the underlying tools

## Support

For issues or questions:

- Check the [Troubleshooting](#troubleshooting) section
- Review the [Customization Guide](./custom-org-context.md)
- Open an issue in this repository
