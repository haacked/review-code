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
  - `find` - Find review for current branch/PR
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
- (no argument) - Run ALL 7 specialized agents in parallel on local changes (default)

**Optional Flags:**

- `--force` or `-f` - Skip the pre-flight context clear prompt
- `--draft` or `-d` - Create a pending GitHub review with inline comments (PR mode only)
- `--self` - Allow creating draft review on your own PR (for testing)

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

**NOTE**: Uses session-based caching to run the orchestrator once and reuse the data across multiple bash invocations. This reduces token usage by ~60%.

**Step 0: Parse Arguments**

Run the parse script to determine the review mode and parameters:

```bash
~/.claude/skills/review-code/scripts/parse-review-arg.sh $ARGUMENTS 2>&1
```

Save the JSON output as `PARSE_RESULT`. Reference this throughout instead of running the parse script again.

**Handler File Selection:**

When directed to load the handler, determine which file to Read based on the `PARSE_RESULT`:

- If `mode` is `"error"`: No handler needed (error flow handles it)
- If `mode` is `"learn"`: Read `~/.claude/skills/review-code/handlers/learn.md`
- If `find_mode` is `"true"`: Read `~/.claude/skills/review-code/handlers/find.md`
- Otherwise: Read `~/.claude/skills/review-code/handlers/review.md`

Use the Read tool to load the selected handler file, then follow its instructions.

**CRITICAL SAFEGUARDS** - These rules are NON-NEGOTIABLE:

1. **NEVER improvise when errors occur** - If any step fails (API errors, script failures, etc.), STOP and inform the user. Do not try to work around failures by posting comments directly or using alternative methods.

2. **NEVER submit reviews without explicit approval** - If the user asks to add comments to a pending review and you cannot amend it, ASK the user if they want to submit the current review first. Never submit on their behalf unless explicitly told to.

3. **NEVER fall back to regular comments** - If `create-draft-review.sh` fails, do NOT post a regular comment as a workaround. This will submit the review instead of keeping it pending.

4. **Follow the structured session flow** - If session initialization fails, STOP and inform the user. NEVER run review agents manually or post to GitHub directly.

### Pre-flight: Clear Context

Code reviews are context-heavy operations and work best with a fresh context.

**If `--force` flag is specified:**
- Skip the context clear prompt entirely and proceed with Step 0.
- The `--force` flag indicates the user wants to proceed without confirmations (typically automation in a clean context).

**If `--force` is NOT specified:**

Use AskUserQuestion:
- Question: "Code reviews work best with a fresh context. Clear conversation history before starting?"
- Options:
  1. "Yes, clear and review (Recommended)" - Clear context, then start the review
     Description: "Ensures clean review without prior conversation influencing results"
  2. "No, continue anyway" - Keep current context and proceed
     Description: "Use only if you need to reference earlier conversation"

If user selects "Yes, clear and review":
- Tell the user: "Please run `/clear` and then run the review command again."
- Stop here - do not proceed with the review.

If user selects "No, continue anyway", proceed with Step 0.

**Skip this prompt entirely if:**
- This is a `find` or `learn` command (lightweight operations that don't need fresh context)
- The context is already fresh (e.g., the user just ran `/clear` or this is the first command in the conversation)

**Note:** Check the `PARSE_RESULT` (pre-computed above). Extract the `mode` field.
If mode is "find" or "learn", skip the pre-flight prompt and proceed directly to the appropriate handler.

### Step 0: Check for Learn Mode

Using the PARSE_RESULT from pre-flight, check if MODE is "learn". If so, load and follow the handler (see Handler File Selection above). Otherwise, continue with Step 1.

### Step 1: Initialize Session

Initialize the review session by running the orchestrator and caching the result:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh init $ARGUMENTS
```

Save the output as `SESSION_ID`. Then get the status:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-status "<SESSION_ID>"
```

Save the output as `STATUS`.

The `--force` and `-f` flags are handled automatically by the orchestrator. When present, the session data will include `"force": true`.

This creates a session and outputs the status. Based on the status, proceed to the appropriate handler below.

**CRITICAL: If session initialization fails, STOP IMMEDIATELY.**

Check for these failure conditions:
- `SESSION_ID` is empty
- Command outputs errors (jq parse errors, "ERROR:", etc.)
- `STATUS` is empty or not one of: `error`, `ambiguous`, `prompt`, `prompt_pull`, `find`, `ready`

**If ANY of these occur:**
1. Tell the user: "Session initialization failed. Please check the error output above."
2. **DO NOT attempt to run the review manually or improvise.**
3. **DO NOT use `gh pr review` or any GitHub API calls directly.**
4. **DO NOT run review agents without a valid session.**
5. Suggest the user run the command again or check for issues.

This safeguard exists because when the session flow breaks, falling back to manual review posting can accidentally submit reviews instead of keeping them as drafts.

**IMPORTANT**: Save the `$SESSION_ID` value from the output - you'll need it for all subsequent operations.

### Handler: "error"

If STATUS is "error", get the error message from the session (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-error-data "<SESSION_ID>"
```

Display the error to the user. Then clean up the session:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

Then stop - do not proceed with review.

### Handler: "ambiguous"

If STATUS is "ambiguous", get the disambiguation data from the session (replace `<SESSION_ID>` with the actual session ID):

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

If STATUS is "prompt", get the prompt data from the session (replace `<SESSION_ID>` with the actual session ID):

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

If STATUS is "prompt_pull", get the pull prompt data from the session (replace `<SESSION_ID>` with the actual session ID):

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
