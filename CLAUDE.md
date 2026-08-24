# Development Guidelines for review-code

## File Locations

This repo contains the source files for the `/review-code` skill:

- `skills/review-code/SKILL.md` - Skill definition (routing + small handlers)
- `skills/review-code/handlers/` - Large handlers loaded on demand (find, review, learn)
- `skills/review-code/scripts/` - Bash scripts that implement the skill
- `skills/review-code/context/` - Base context files (languages, frameworks, orgs)
- `skills/review-code/learnings/` - Learning system documentation
- `agents/` - Agent definitions
- `bin/` - Development utilities (fmt, lint, test, setup)

## Agent Definitions

The nine domain reviewers in `agents/` deliberately repeat four shared blocks instead of sourcing them from one file: "Before You Review", "Self-Challenge", the confidence rubric, and the finding format (a fenced ```text body plus the `Location: path:line | Confidence: NN%` trailer). Each subagent receives its own prompt exactly once, so deduplicating would save no runtime tokens; keep the four blocks in sync when editing one. The finding format is parsed by `parse-review-findings.sh` and the synthesis step in `handlers/review.md`; don't change its shape.

## Architecture

**In the repository:**

```
skills/review-code/
    SKILL.md                          # Skill definition (routing + small handlers)
    handlers/                         # Large handlers loaded on demand
        find.md
        review.md
        learn.md
    briefing/                         # Static text concatenated into the agent briefing
        shared-instructions.md
    scripts/                          # Helper scripts
    context/                          # Base context files (shipped to users)
        languages/
        frameworks/
        orgs/
    learnings/                        # Learning system docs
agents/                               # Review agent definitions
```

**Installed at `~/.agents/skills/review-code/`:**

```
~/.agents/skills/review-code/
    SKILL.md
    handlers/                         # Large handlers loaded on demand
        find.md
        review.md
        learn.md
    scripts/
    context/                          # Base + user learnings (merged)
        languages/
        frameworks/
        orgs/
    .reviews/                         # Review outputs (org/repo/pr.md)
        posthog/
            posthog/
                pr-123.md
    .learnings/                       # Learning index
        index.jsonl
        analyzed.json
    .sessions/                        # Session state, pre-flight markers, and per-review artifacts
        review-code/
            artifacts-XXXXXX/         # diff.patch, briefing.md, scoped diffs (swept with the session)
    .worktrees/                       # PR checkout worktrees (org/repo/pr-N)
```

**Key insight:** The repo structure mirrors the installed structure, except that runtime state (reviews, learnings, sessions, worktrees) is installed into dot-prefixed directories so skill scanners that ignore dot-directories don't count it against the skill's file budget (source `learnings/README.md` installs to `.learnings/README.md`). During setup, `skills/review-code/` is copied to `~/.agents/skills/review-code/`. User learnings applied to installed context are preserved through smart merge - new sections from base are added, but existing sections (which may contain learned patterns) are kept.

## Keeping Reviews Cheap

A review's cost is the orchestrating conversation's context multiplied by its turn count, plus everything the orchestrator has to write out. Two rules follow, and breaking either one is expensive in a way that is invisible in a single run:

- **Never put a large payload in an agent prompt.** The diff, the review context, the PR body and comments all live in files under the session's `artifacts_dir`. `build-agent-briefing.sh` writes them once; agent prompts carry a path. Inlining any of them means the orchestrator writes it once per agent, at output-token prices.
- **Never Read the session file wholesale.** Use `review-status-handler.sh get-review-fields`, which returns the small orchestration fields and deliberately excludes `diff`, `review_context`, `pr.body`, and `pr.comments`. Anything added to that accessor is paid for on every later turn of the run.

`handlers/review.md` is read on every review, so its length is also multiplied by the turn count. Stage-specific instructions belong in an on-demand handler (see `review-compose.md`, `review-pr-output.md`, `review-inline-fallback.md`), and mechanical steps belong in a script rather than in prose the model has to carry (see `log-token-usage.sh`).

Measure with `bin/token-report` before and after. The skill's own `.reviews/token-usage.jsonl` sees subagents only, and the orchestrator is roughly half the bill.

## Important: Edit Source Files Only

**Never edit files in `~/.agents/` or `~/.claude/skills/review-code/` directly.** Always edit the source files in this repo.

The trees at `~/.agents/skills/review-code/` (canonical, Codex + Claude) and at `~/.claude/skills/review-code/` (symlink to canonical) are installed copies. To update them after making changes:

```bash
bin/setup
```

This copies the source files to the canonical location, maintains the symlink, renders Codex agent TOMLs, and uses smart merge for context files to preserve user learnings.

## Codex Support

The skill runs under both Claude Code (native Task tool dispatch) and OpenAI Codex (`codex exec` subprocess dispatch). `~/.agents/skills/review-code` is the canonical install location; `~/.claude/skills/review-code` is a symlink to it. Agent definitions in `agents/*.md` are the single source for both Claude (installed as `.md`) and Codex (rendered to `.toml` by `bin/render-codex-agents.py` and staged under `~/.codex/.review-code-agents/`).

Claude-only features the skill gates on harness detection:
- The `/clear` resume marker + SessionStart hook (Codex has no hook system)
- The `PreToolUse` safety hook (Codex has no per-skill tool scoping)
- Per-agent Task resume for coverage validation and finding-validator callbacks

If you change an agent definition's `model:` value, keep `codex/model-tiers.conf` in sync; `bin/render-codex-agents.py` fails on any model it doesn't recognize.

## Testing Changes

After editing source files:

1. Run `bin/setup` to install changes to `~/.agents/`
2. Test the skill with `/review-code` in a Claude Code session
3. Run `bin/test` to run the test suite

## Formatting

Before committing, run:

```bash
bin/fmt
```

This formats shell scripts with shfmt.
