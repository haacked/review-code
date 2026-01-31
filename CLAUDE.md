# Development Guidelines for review-code

## File Locations

This repo contains the source files for the `/review-code` skill:

- `commands/` - Skill definition files (markdown)
- `lib/` - Bash scripts that implement the skill
- `agents/` - Agent definitions (YAML)
- `context/` - Review context files
- `bin/` - Development utilities (fmt, lint, test, setup)

## Important: Edit Source Files Only

**Never edit files in `~/.claude/` directly.** Always edit the source files in this repo.

The files in `~/.claude/bin/review-code/` are installed copies. To update them after making changes:

```bash
bin/setup
```

This copies the source files to the appropriate locations in `~/.claude/`.

## Testing Changes

After editing source files:

1. Run `bin/setup` to install changes to `~/.claude/`
2. Test the skill with `/review-code` in a Claude Code session
3. Run `bin/test` to run the test suite

## Formatting

Before committing, run:

```bash
bin/fmt
```

This formats shell scripts with shfmt.
