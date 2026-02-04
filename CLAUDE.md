# Development Guidelines for review-code

## File Locations

This repo contains the source files for the `/review-code` skill:

- `skills/review-code/SKILL.md` - Skill definition
- `skills/review-code/scripts/` - Bash scripts that implement the skill
- `skills/review-code/learnings/` - Learning system documentation
- `agents/` - Agent definitions
- `context/` - Base context files (languages, frameworks, orgs)
- `bin/` - Development utilities (fmt, lint, test, setup)

## Architecture

**In the repository:**

```
context/                              # Base context files (shipped to users)
    languages/
    frameworks/
    orgs/
skills/review-code/
    SKILL.md                          # Skill definition
    scripts/                          # Helper scripts
    learnings/                        # Learning system docs
agents/                               # Review agent definitions
```

**Installed at `~/.claude/skills/review-code/`:**

```
~/.claude/skills/review-code/
    SKILL.md
    scripts/
    context/                          # Base + user learnings (merged)
        languages/
        frameworks/
        orgs/
    reviews/                          # Review outputs (org/repo/pr.md)
        posthog/
            posthog/
                pr-123.md
    learnings/                        # Learning index
        index.jsonl
        analyzed.json
```

**Key insight:** The repo's `context/` is the base. During setup, it's merged into `~/.claude/skills/review-code/context/`. User learnings applied to installed context are preserved through smart merge - new sections from base are added, but existing sections (which may contain learned patterns) are kept.

## Important: Edit Source Files Only

**Never edit files in `~/.claude/` directly.** Always edit the source files in this repo.

The files in `~/.claude/skills/review-code/` are installed copies. To update them after making changes:

```bash
bin/setup
```

This copies the source files to the appropriate locations and uses smart merge for context files to preserve user learnings.

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
