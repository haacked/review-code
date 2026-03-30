---
description: Run specialized code review agents on code changes or pull requests
argument-hint: [find|learn|pr|commit|branch|range|area]
allowed-tools: Bash(~/.claude/skills/review-code/scripts/*:*), Read(~/.claude/**), Write(~/.claude/skills/review-code/learnings/*), Edit(~/.claude/skills/review-code/learnings/*)
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: ~/.claude/skills/review-code/scripts/review-safety-hook.sh
---

Run specialized code review agent(s) with comprehensive context on local changes or pull requests.

**Arguments:**

- `find` - Find existing review notes without starting a new review
  - `find` (no argument) - Find review for current branch/PR
  - `find <pr-number>` - Find review for specific PR (e.g., `find 123`)
  - `find <branch>` - Find review for specific branch (e.g., `find feature-branch`)
- `learn` - Learn from PR review outcomes to improve future reviews
  - `learn <pr-number>` - Analyze outcomes of a specific PR (e.g., `learn 123`)
  - `learn` - Batch analyze all unanalyzed PRs with existing reviews
  - `learn --apply` - Apply accumulated learnings to context files
- `<pr-url>` - Review Pull Request by URL - works from anywhere (e.g., `https://github.com/org/repo/pull/123`)
  - Uses `gh` CLI to fetch PR context from GitHub
  - No git repository required - review any PR without cloning
  - Automatically uses local git for speed when on PR's branch
- `<commit>` - Review that specific commit's changes (e.g., `356ded2`)
- `<branch>` - Review all changes in branch vs base (e.g., `feature-branch`)
- `<range>` - Review specific git range (e.g., `abc123..HEAD`, `v1.0.0..v2.0.0`)
- `security` - Deep security vulnerability analysis only (local changes)
- `performance` - Performance bottlenecks and optimization only (local changes)
- `correctness` - Functional correctness, intent verification, and integration boundaries only (local changes)
- `maintainability` - Code clarity, simplicity, and maintainability only (local changes)
- `testing` - Test coverage, quality, and patterns only (local changes)
- `compatibility` - Backwards compatibility with shipped code only (local changes)
- `architecture` - High-level design, patterns, and necessity only (local changes)
- `infra-config` - Infrastructure config review: Helm, Terraform, K8s, ArgoCD, CI/CD (local changes)
- (no argument) - Run the 7 core agents in parallel on local changes; also runs `infra-config` and `frontend` when the diff contains those file types (default)

**Optional Flags:**

- `--force` or `-f` - Skip the pre-flight context clear prompt
- `--draft` or `-d` - Create a pending GitHub review with inline comments (PR mode only). Automatically detects and adjusts for comment drift when the PR receives new commits between review generation and draft posting.
- `--self` - Allow creating draft review on your own PR (for testing)
- `--overwrite` - Replace existing review file without prompting
- `--append` - Append to existing review file without prompting

**Optional File Pattern:**

Add a file pattern as a second argument to filter changes by file:
- `<arg> <pattern>` - Review only files matching the pattern (e.g., `356ded2..HEAD "*.sh"`)

Examples:
- `/review-code 356ded2..HEAD "*.sh"` - Review only shell script changes in range
- `/review-code "lib/*.sh"` - Review only shell scripts in lib/ (local changes)
- `/review-code feature-branch "*.py"` - Review only Python files in branch
- `/review-code 123 "src/**/*.ts"` - Review only TypeScript files in PR #123

**Usage examples:**

- `/review-code` - Comprehensive review of local uncommitted changes (default)
- `/review-code https://github.com/org/repo/pull/123` - Review any PR by URL (works from anywhere!)
- `/review-code 356ded2` - Review that specific commit
- `/review-code feature-branch` - Review all changes in branch vs main
- `/review-code abc123..HEAD` - Review changes from abc123 to HEAD
- `/review-code security` - Run only security review on local changes
- `/review-code find 123` - Find review for PR #123
- `/review-code learn 123` - Analyze what happened after reviewing PR #123
- `/review-code 123 --draft -f` - Review PR, create draft review, skip confirmation

---

## Implementation

Uses session-based caching to run the orchestrator once and reuse data across bash invocations. This reduces token usage by ~60%.

**CRITICAL SAFEGUARDS** - These rules are NON-NEGOTIABLE:

1. **NEVER improvise when errors occur** - If any step fails (API errors, script failures, etc.), STOP and inform the user. Do not try to work around failures.

2. **NEVER submit reviews without explicit approval** - If the user asks to add comments to a pending review and you cannot amend it, ASK before submitting. Never submit on their behalf unless explicitly told to.

3. **NEVER fall back to regular comments** - If `create-draft-review.sh` fails, do NOT post a regular comment as a workaround. This submits the review instead of keeping it pending.

4. **Follow the structured session flow** - If session initialization fails, STOP and inform the user. NEVER run review agents manually or post to GitHub directly.

### Step 1: Parse Arguments

Run the parse script to determine the review mode and parameters:

```bash
~/.claude/skills/review-code/scripts/parse-review-arg.sh $ARGUMENTS 2>&1
```

Save the JSON output as `PARSE_RESULT`. Reference this throughout — do not run the parse script again.

**Handler File Selection:**

When directed to load a handler, select the file based on `PARSE_RESULT`:

- If `mode` is `"error"`: No handler needed (error flow handles it)
- If `mode` is `"learn"`: Read `~/.claude/skills/review-code/handlers/learn.md`
- If `find_mode` is `"true"`: Read `~/.claude/skills/review-code/handlers/find.md`
- Otherwise: Read `~/.claude/skills/review-code/handlers/review.md`

Use the Read tool to load the selected handler file, then follow its instructions.

**If `mode` is `"learn"`:** Load and follow the learn handler now (see Handler File Selection above). Do not proceed to Step 2 or Step 3.

**If `find_mode` is `"true"`:** Skip the pre-flight prompt and go directly to Step 3 (Initialize Session). The session handler will route to the find handler.

### Step 2: Pre-flight Context Check

Code reviews are context-heavy and work best with a fresh context.

**If `--force` was specified:** Skip this step entirely and proceed to Step 3.

**Otherwise**, use AskUserQuestion:
- Question: "Code reviews work best with a fresh context. Clear conversation history before starting?"
- Options:
  1. "Yes, clear and review (Recommended)" - Clear context, then start the review
     Description: "Ensures clean review without prior conversation influencing results"
  2. "No, continue anyway" - Keep current context and proceed
     Description: "Use only if you need to reference earlier conversation"

If user selects "Yes, clear and review":
- Tell the user: "Please run `/clear` and then run the review command again."
- Stop here.

If user selects "No, continue anyway", proceed to Step 3.

### Step 3: Initialize Session

Initialize the review session by running the orchestrator and caching the result:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh init $ARGUMENTS
```

Save the output as `SESSION_ID` — you'll need it for all subsequent operations. Then get the status:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-status "<SESSION_ID>"
```

Save the output as `STATUS`. The `--force`/`-f` flags are handled automatically; when present, the session data will include `"force": true`.

**CRITICAL: If session initialization fails, STOP IMMEDIATELY.**

Failure conditions:
- `SESSION_ID` is empty
- Command outputs errors (jq parse errors, "ERROR:", etc.)
- `STATUS` is empty or not one of: `error`, `ambiguous`, `prompt`, `prompt_pull`, `find`, `ready`

If any failure condition is met: tell the user "Session initialization failed. Please check the error output above" and stop. Do not improvise, call GitHub APIs directly, or run review agents without a valid session. Falling back to manual posting can accidentally submit reviews instead of keeping them as drafts.

In all handlers below, substitute the actual `SESSION_ID` value when calling scripts.

### Handler: "error"

If STATUS is "error", get the error message:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-error-data "<SESSION_ID>"
```

Display the error to the user. Then clean up the session:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

Stop — do not proceed with review.

### Handler: "ambiguous"

If STATUS is "ambiguous", get the disambiguation data:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-ambiguous-data "<SESSION_ID>"
```

Save the JSON output. Extract the fields: `arg`, `ref_type`, `is_branch`, `is_current`, `base_branch`.

Use AskUserQuestion to disambiguate based on the scenario.

**For commits:**
- Question: "The reference '$arg' is a commit. What would you like to review?"
- Options:
  1. "This commit only" - Review just the changes in commit $arg
  2. "Changes since this commit" - Review all changes from $arg to HEAD

**For current branch:**
- Question: "You're on branch '$arg'. What would you like to review?"
- Options:
  1. "Uncommitted changes" - Review only staged and unstaged files
  2. "Branch changes" - Review all changes in $arg vs $base_branch
  3. "Both" - Review branch changes plus uncommitted

**For other branches:**
- Question: "What would you like to review?"
- Options:
  1. "Branch $arg" - Review all changes in $arg vs $base_branch
  2. "Changes up to $arg" - Review all changes from $arg to HEAD

After user selects, re-run orchestrator with appropriate argument.

### Handler: "prompt"

If STATUS is "prompt", get the prompt data:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-prompt-data "<SESSION_ID>"
```

Save the JSON output. Extract the fields: `current_branch`, `base_branch`, `has_uncommitted`.

Use AskUserQuestion:
- Question: "You're on branch '$current_branch' with uncommitted changes. What would you like to review?"
- Options:
  1. "Uncommitted only" - Review staged and unstaged files only
  2. "Branch changes" - Review all changes vs $base_branch
  3. "Comprehensive" - Review branch + uncommitted changes

After user selects, cleanup the old session and re-initialize with the chosen mode.

### Handler: "prompt_pull"

If STATUS is "prompt_pull", get the pull prompt data:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-prompt-pull-data "<SESSION_ID>"
```

Save the JSON output. Extract the fields: `branch`, `associated_pr` (defaults to "none").

Use AskUserQuestion:
- Question: "Remote branch '$branch' is ahead of local. Would you like to pull changes first?"
- Options:
  1. "Pull and review" - Run `git pull` then proceed with review
  2. "Review local anyway" - Review the local branch as-is

After user selects:
- If "Pull and review": Run `git pull`, cleanup old session, then reinitialize with empty argument
- If "Review local anyway": Cleanup old session, then reinitialize with the branch name explicitly

### Handler: "find"

If STATUS is "find", load and follow the handler (see Handler File Selection above).

### Handler: "ready"

If STATUS is "ready", load and follow the handler (see Handler File Selection above).
