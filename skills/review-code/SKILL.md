---
description: Run specialized code review agents on code changes or pull requests
argument-hint: [find|pr|commit|branch|range|area]
---

Run specialized code review agent(s) with comprehensive context on local changes or pull requests.

**Arguments:**

- `find` - Find existing review notes without starting a new review
  - `find` - Find review for current branch/PR
  - `find <pr-number>` - Find review for specific PR (e.g., `find 123`)
  - `find <branch>` - Find review for specific branch (e.g., `find feature-branch`)
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

- `--force` or `-f` - Skip the confirmation prompt and proceed directly with review
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
- `/review-code v1.0.0..v2.0.0` - Review changes between two tags
- `/review-code security` - Run only security review on local changes
- `/review-code maintainability` - Run only maintainability review on local changes

**Find existing reviews:**

- `/review-code find` - Find review for current branch/PR
- `/review-code find 123` - Find review for PR #123
- `/review-code find feature-branch` - Find review for a specific branch

**With file patterns:**

- `/review-code 356ded2..HEAD "*.sh"` - Review only shell script changes in range
- `/review-code "lib/*.sh"` - Review only shell scripts in lib/ directory (local)
- `/review-code feature-branch "*.py"` - Review only Python files in branch
- `/review-code https://github.com/org/repo/pull/123 "src/**/*.ts"` - Review only TypeScript files in PR
- `/review-code security "*.rs"` - Security review of only Rust files (local)

**With --force flag (skip confirmation):**

- `/review-code --force` - Review local changes without confirmation
- `/review-code https://github.com/org/repo/pull/123 --force` - Review PR without confirmation
- `/review-code -f feature-branch` - Short form, review branch without confirmation

**With --draft flag (create pending GitHub review):**

- `/review-code https://github.com/org/repo/pull/123 --draft` - Review PR and create draft review on GitHub
- `/review-code 123 --draft` - Review PR #123 and create draft review
- `/review-code 123 --draft --force` - Review PR without confirmation and create draft
- `/review-code 123 -d -f` - Short form, review PR #123, skip confirmation, create draft
- `/review-code 123 --draft --self` - Create draft review on your own PR (for testing)

---

## Implementation

**NOTE**: Uses session-based caching to run the orchestrator once and reuse the data across multiple bash invocations. This reduces token usage by ~60%.

### Step 1: Initialize Session

Initialize the review session by running the orchestrator and caching the result:

```bash
SESSION_ID=$(~/.claude/skills/review-code/scripts/review-status-handler.sh init $ARGUMENTS)
STATUS=$(~/.claude/skills/review-code/scripts/review-status-handler.sh get-status "$SESSION_ID")
echo "Session: $SESSION_ID, Status: $STATUS"
```

The `--force` and `-f` flags are handled automatically by the orchestrator. When present, the session data will include `"force": true`.

This creates a session and outputs the status. Based on the status, proceed to the appropriate handler below.

**IMPORTANT**: Save the `$SESSION_ID` value from the output - you'll need it for all subsequent operations.

### Handler: "error"

If STATUS is "error", get the error message from the session (replace `<SESSION_ID>` with the actual session ID):

```bash
bash -c '
SESSION_ID="<SESSION_ID>"
error_msg=$(~/.claude/skills/review-code/scripts/review-status-handler.sh get-error-data "$SESSION_ID")
echo "Error: $error_msg"
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "$SESSION_ID"
'
```

Then stop - do not proceed with review.

### Handler: "ambiguous"

If STATUS is "ambiguous", get the disambiguation data from the session (replace `<SESSION_ID>` with the actual session ID):

```bash
bash -c '
SESSION_ID="<SESSION_ID>"
data=$(~/.claude/skills/review-code/scripts/review-status-handler.sh get-ambiguous-data "$SESSION_ID")
arg=$(echo "$data" | jq -r ".arg")
ref_type=$(echo "$data" | jq -r ".ref_type")
is_branch=$(echo "$data" | jq -r ".is_branch")
is_current=$(echo "$data" | jq -r ".is_current")
base_branch=$(echo "$data" | jq -r ".base_branch")
echo "Reference: $arg (type: $ref_type, is_branch: $is_branch, is_current: $is_current, base: $base_branch)"
'
```

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
bash -c '
SESSION_ID="<SESSION_ID>"
data=$(~/.claude/skills/review-code/scripts/review-status-handler.sh get-prompt-data "$SESSION_ID")
current_branch=$(echo "$data" | jq -r ".current_branch")
base_branch=$(echo "$data" | jq -r ".base_branch")
has_uncommitted=$(echo "$data" | jq -r ".has_uncommitted")
echo "Branch: $current_branch, Base: $base_branch, Uncommitted: $has_uncommitted"
'
```

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
bash -c '
SESSION_ID="<SESSION_ID>"
data=$(~/.claude/skills/review-code/scripts/review-status-handler.sh get-prompt-pull-data "$SESSION_ID")
branch=$(echo "$data" | jq -r ".branch")
associated_pr=$(echo "$data" | jq -r ".associated_pr // \"none\"")
echo "Branch: $branch, Associated PR: $associated_pr"
'
```

Use AskUserQuestion:
- Question: "Remote branch '$branch' is ahead of local. Would you like to pull changes first?"
- Options:
  1. "Pull and review" - Run `git pull` then proceed with review
  2. "Review local anyway" - Review the local branch as-is

After user selects:
- If "Pull and review": Run `git pull`, cleanup old session, then reinitialize with empty argument
- If "Review local anyway": Cleanup old session, then reinitialize with the branch name explicitly

### Handler: "find"

If STATUS is "find", get the find data from the session and display the result (replace `<SESSION_ID>` with the actual session ID):

```bash
bash -c '
SESSION_ID="<SESSION_ID>"
find_data=$(~/.claude/skills/review-code/scripts/review-status-handler.sh get-find-data "$SESSION_ID")
display_target=$(echo "$find_data" | jq -r ".display_target")
file_path=$(echo "$find_data" | jq -r ".file_info.file_path")
file_exists=$(echo "$find_data" | jq -r ".file_info.file_exists")
file_summary=$(echo "$find_data" | jq -r ".file_summary")
has_branch_review=$(echo "$find_data" | jq -r ".file_info.has_branch_review // false")
branch_review_path=$(echo "$find_data" | jq -r ".file_info.branch_review_path // empty")
needs_rename=$(echo "$find_data" | jq -r ".file_info.needs_rename // false")
pr_number=$(echo "$find_data" | jq -r ".file_info.pr_number // empty")
echo "Target: $display_target"
echo "File: $file_path"
echo "Exists: $file_exists"
echo "Has branch review: $has_branch_review"
echo "Branch review path: $branch_review_path"
echo "Needs rename: $needs_rename"
echo "PR number: $pr_number"
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "$SESSION_ID"
'
```

**Present the results to the user:**

If `file_exists` is "true":
- Display: "Found existing review for $display_target"
- Show the file path as a clickable link: `file://$file_path`
- Show a brief summary from `file_summary` (the first ~50 lines of the review file)
- Offer to open or read the full review

**If `has_branch_review` is "true" (both PR and branch reviews exist):**
- Display a warning: "⚠️ A branch-based review also exists that can be merged"
- Show the branch review path: `$branch_review_path`
- Use AskUserQuestion to offer merge options:
  - Question: "A branch review exists alongside the PR review. What would you like to do?"
  - Options:
    1. "Merge into PR review" - Append branch review content to PR review, then delete branch review
    2. "Keep both" - Leave both files as-is
    3. "Delete branch review" - Remove the branch review file (content already in PR review)

If user selects "Merge into PR review":
1. Read both files using the Read tool
2. Append the branch review content to the PR review with a separator like `\n\n---\n\n## Previous Branch Review\n\n`
3. Write the merged content to the PR review file
4. Delete the branch review file using Bash: `rm "$branch_review_path"`
5. Confirm: "Merged branch review into PR review and deleted the old file."

**If `needs_rename` is "true" (branch review exists, PR exists but no PR review):**
- Display: "Found branch review for $display_target"
- Show that a PR (#$pr_number) now exists for this branch
- Use AskUserQuestion to offer migration:
  - Question: "A PR (#$pr_number) now exists for this branch. Migrate the review?"
  - Options:
    1. "Migrate to PR review" - Rename the file from branch to PR format
    2. "Keep as branch review" - Leave the file as-is

If user selects "Migrate to PR review":
1. Compute the new path: replace `$file_path` filename with `pr-$pr_number.md`
2. Move the file using Bash: `mv "$file_path" "$new_path"`
3. Confirm: "Migrated review to $new_path"

If `file_exists` is "false":
- Display: "No existing review found for $display_target"
- Show where the review would be saved: `$file_path`
- Suggest running `/review-code` (without `find`) to create a new review

Then stop - do not proceed with review agents.

### Handler: "ready"

If STATUS is "ready", get the session file path and read data directly from the file (replace `<SESSION_ID>` with the actual session ID):

```bash
bash -c '
SESSION_ID="<SESSION_ID>"
SESSION_FILE=$(~/.claude/skills/review-code/scripts/review-status-handler.sh get-session-file "$SESSION_ID")
display_summary=$(jq -r ".display_summary" "$SESSION_FILE")
echo "$display_summary"
'
```

This displays the pre-formatted summary showing what will be reviewed.

**All subsequent operations will use the same SESSION_FILE to read from the cached session data.**

**Ask user to confirm (unless --force was specified):**

Check if the `force` flag is set in the session data:

```bash
force_flag=$(jq -r ".force // false" "$SESSION_FILE")
```

If `force_flag` is `true`, skip the confirmation and proceed directly with the review below.

Otherwise, use AskUserQuestion:
- Question: "Proceed with code review of these changes?"
- Options:
  1. "Yes, review these changes" - Proceed with the review
     Description: "Run comprehensive code review agents on the changes above"
  2. "Cancel" - Exit without reviewing
     Description: "Stop and return without running review"

If user selects "Cancel", exit without proceeding.

If user selects "Yes, review these changes" (or if `force_flag` is `true`), continue with the review below.

**Check for existing review and branch review (using `$SESSION_FILE` from above):**

```bash
jq -r '{
  existing: (if .file_info.file_exists == true then .file_info.file_path else null end),
  has_branch_review: (.file_info.has_branch_review // false),
  branch_review_path: (.file_info.branch_review_path // null),
  needs_rename: (.file_info.needs_rename // false),
  pr_number: (.file_info.pr_number // null)
}' "$SESSION_FILE"
```

**If `has_branch_review` is true (both PR and branch reviews exist):**

Use AskUserQuestion:
- Question: "A branch review exists alongside the PR review. Merge before proceeding?"
- Options:
  1. "Merge and continue" - Merge branch review into PR review, then proceed with new review
  2. "Continue without merging" - Keep both files, proceed with review
  3. "Cancel" - Stop and handle manually

If user selects "Merge and continue":
1. Read both files using the Read tool
2. Append branch review content to PR review with separator: `\n\n---\n\n## Previous Branch Review\n\n`
3. Write merged content to PR review file
4. Delete branch review file: `rm "$branch_review_path"`
5. Continue with the review

**If `needs_rename` is true (branch review exists, but should migrate to PR):**

Use AskUserQuestion:
- Question: "A PR (#$pr_number) exists. Migrate branch review to PR format before proceeding?"
- Options:
  1. "Migrate and continue" - Rename to PR format, then proceed
  2. "Continue as branch review" - Keep current format, proceed
  3. "Cancel" - Stop and handle manually

If user selects "Migrate and continue":
1. Compute new path with `pr-$pr_number.md` filename
2. Move file: `mv "$file_path" "$new_path"`
3. Update `review_file` variable to new path
4. Continue with the review

**If `existing` is not null (review file already exists):**

Use AskUserQuestion to ask what to do with the existing review.

**Extract the data needed for building agent context (using `$SESSION_FILE` from above):**

All subsequent extractions use the SAME SESSION_FILE (no re-running orchestrator). Extract individual fields as needed using jq directly on the file:
- `mode=$(jq -r ".mode" "$SESSION_FILE")`
- `diff=$(jq -r ".diff" "$SESSION_FILE")`
- `file_metadata=$(jq -r ".file_metadata" "$SESSION_FILE")`
- `review_context=$(jq -r ".review_context" "$SESSION_FILE")`
- `git_context=$(jq -r ".git" "$SESSION_FILE")`
- `languages=$(jq -r ".languages" "$SESSION_FILE")`
- `review_file=$(jq -r ".file_info.file_path" "$SESSION_FILE")`

**Extract mode-specific fields from the cached session (using `$SESSION_FILE`):**

Extract mode-specific fields as needed:
- **For PR mode:** `pr=$(jq -r ".pr // empty" "$SESSION_FILE")`
- **For branch/commit/range modes:**
  - `branch=$(jq -r ".branch // empty" "$SESSION_FILE")`
  - `base_branch=$(jq -r ".base_branch // empty" "$SESSION_FILE")`
  - `commit=$(jq -r ".commit // empty" "$SESSION_FILE")`
  - `range=$(jq -r ".range // empty" "$SESSION_FILE")`
- **For area-specific reviews:** `area=$(jq -r ".area // empty" "$SESSION_FILE")`

### Gather Architectural Context

Before invoking specialized agents, use the context explorer to understand the codebase:

Invoke the Task tool with subagent_type "Explore" and prompt:

```markdown
Gather architectural context for this code review.

**File Metadata:**
$file_metadata

**Diff:**
$diff

Explore the codebase to understand:
- Full context of modified files
- Related code and dependencies
- Existing patterns for similar functionality
- Reusable utilities or conventions

Time-box yourself to 2-3 minutes of exploration.
```

Save the explorer's output as: `architectural_context="<output from Task>"`

### Invoke Specialized Review Agents

Now invoke the appropriate review agent(s) based on the mode and area.

**Build the context to pass to agents:**

```markdown
{For PR mode:}
You are reviewing Pull Request #$pr_number: "$pr_title"

**PR Details:**
- URL: $pr_url
- Author: $pr_author
- Branch: (from pr data) → (to pr data)
- Status: (from pr data)

**PR Description:**
$pr_body

**Existing Review Comments:**
$pr_comments

{For commit mode:}
Reviewing commit: $commit

{For branch mode with associated PR:}
Reviewing branch: $branch vs $base_branch

**Associated Pull Request:**
- PR #$pr_number: $pr_title
- Author: $pr_author
- State: $pr_state
- URL: $pr_url

**PR Description:**
$pr_body

**PR Discussion:**
$pr_comments

{For branch mode without PR:}
Reviewing branch: $branch vs $base_branch

{For range mode:}
Reviewing range: $range

{For all modes:}
**Code Changes:**
$diff

**Architectural Context:**
$architectural_context

{If review_context not empty:}
**Language/Framework-Specific Guidelines:**
$review_context

{If previous_review exists:}
**Previous Review:**
$previous_review

IMPORTANT: Build upon the previous review. Do not duplicate findings. You may:
- Reference previous findings: "As noted in the previous review..."
- Add new findings discovered since last review
- Update status if code changed
- Mark findings as resolved if fixed
```

**Handling Existing PR Comments:**

When the context includes PR comments (`$pr_comments`), instruct agents to:
1. **Never claim credit** for issues already identified by other reviewers
2. **Evaluate each finding** - Is it legitimate? Correct? A false positive?
3. **Attribute with assessment**: `[Found by @username] Issue description` + your analysis
4. **Track fix status**: `✅ Fixed in <commit>`, `Open`, or `Invalid`
5. **Summarize at the start** in a table:
   ```
   | Issue | Found By | Status | Assessment |
   |-------|----------|--------|------------|
   | N+1 query | @bot | ✅ Fixed | Valid - good catch |
   | Missing null check | @reviewer | Open | Valid - needs fix |
   | Unused import | @linter | Invalid | False positive - used in macro |
   ```
6. **Focus on NEW findings** not already raised

Comment structure: `conversation` (discussion), `reviews` (approve/changes), `inline` (line-level with `path`, `line`, `author`, `body`)

**Determine which agents to invoke:**

Use the Task tool with `subagent_type` set to the agent name, passing the full context as the `prompt`.

**If area is "security"**: Use Task tool with `subagent_type: "code-reviewer-security"`
**If area is "performance"**: Use Task tool with `subagent_type: "code-reviewer-performance"`
**If area is "correctness"**: Use Task tool with `subagent_type: "code-reviewer-correctness"`
**If area is "maintainability"**: Use Task tool with `subagent_type: "code-reviewer-maintainability"`
**If area is "testing"**: Use Task tool with `subagent_type: "code-reviewer-testing"`
**If area is "compatibility"**: Use Task tool with `subagent_type: "code-reviewer-compatibility"`
**If area is "architecture"**: Use Task tool with `subagent_type: "code-reviewer-architecture"`

**If no area specified (comprehensive review)**:

First, check if this is frontend code by inspecting the languages data
(using `$SESSION_FILE` from above):

```bash
has_frontend=$(jq -r ".languages.has_frontend // false" "$SESSION_FILE")
```

**Always invoke these 7 core agents in PARALLEL using the Task tool:**

For each agent, use the Task tool with:
- `subagent_type`: The agent name (e.g., "code-reviewer-security")
- `prompt`: The full context built above (PR details, diff, architectural context, etc.)
- `description`: Short description like "Security review"

Agents to invoke:
1. `code-reviewer-security` - Focus: vulnerabilities, exploits, security hardening
2. `code-reviewer-performance` - Focus: bottlenecks, inefficiencies, optimization
3. `code-reviewer-correctness` - Focus: intent verification, integration boundaries, functional correctness
4. `code-reviewer-maintainability` - Focus: readability, simplicity, long-term code health
5. `code-reviewer-testing` - Focus: test coverage, quality, edge cases
6. `code-reviewer-compatibility` - Focus: backwards compatibility with shipped code
7. `code-reviewer-architecture` - Focus: necessity, patterns, code reuse, simplicity

**If `has_frontend` is true**, also invoke in the same parallel batch:
8. `code-reviewer-frontend` - Focus: React/TypeScript patterns, component design, state management, accessibility

**IMPORTANT:** Pass the FULL context (PR info, diff, architectural context, guidelines) to each agent as the prompt. Agents cannot review code without receiving the actual code changes.

### Collect and Present Results

After all agents complete, combine their findings into a single review document.

**Format the review based on mode:**

**PR Review Title:**
```
Pull Request Review: #$pr_number - $pr_title
```

**Commit Review Title:**
```
Commit Review: $commit
```

**Branch Review Title:**
```
Branch Review: $branch vs $base_branch
```

**Range Review Title:**
```
Range Review: $range
```

**Local Review Title:**
```
Code Review: (org/repo from git_context) - (branch) (uncommitted)
```

**For comprehensive reviews**, include sections for each area:
- Security Review
- Performance Review
- Correctness Review
- Maintainability Review
- Testing Review
- Compatibility Review
- Architecture Review

**For area-specific reviews**, include only that area's findings.

Save the complete review to `$review_file` and inform the user with a clickable file link:

```
Review complete!

{If PR mode:}
🔗 Pull Request: $pr_url

📄 Review saved to: $review_file

You can open it directly: file://$review_file
```

**CRITICAL: Do NOT post the full review to GitHub.** The detailed review is saved to the markdown file only. If `--draft` mode is enabled, a separate draft review with inline comments will be created in the next step - but that draft should contain only brief inline comments, NOT the full review summary.

### Generate Suggested Comments (PR Mode Only)

If this is a PR review and the reviewer is NOT the PR author, generate suggested inline comments for the review file. This helps the reviewer quickly identify what comments to post on the PR.

**Check if suggested comments should be generated:**

Extract from session data (using `$SESSION_FILE`):

```bash
is_own_pr=$(jq -r '.is_own_pr // false' "$SESSION_FILE")
inline_comments=$(jq '.pr.comments.inline // []' "$SESSION_FILE")
```

**If `is_own_pr` is "false":**

When combining agent findings into the review document, add a "Suggested Comments" section with the following:

1. **Extract findings with locations**: From each agent's output, identify findings that have a specific file path and line number.

2. **Check against existing comments**: For each finding, check if there are existing inline comments (from `$inline_comments`) that:
   - Are on the same file
   - Are within 5 lines of the finding
   - Address the same issue (use your judgment on semantic similarity)

3. **Categorize findings**:
   - **New comment**: No existing comment addresses this issue
   - **Build upon existing**: Existing comment is related but incomplete
   - **Already covered**: Existing comment fully addresses the finding

4. **Format the section** following this structure:

```markdown
---

## Suggested Comments

These suggestions are for posting as inline PR review comments.

### New Comments

For each finding that needs a new comment:

#### `<file_path>:<line_number>`

```text
<suggested comment text - clear, constructive, and actionable>
```

*From: <Agent Name> (<confidence>% confidence)*

---

### Build Upon Existing

For findings where there's a related but incomplete existing comment:

#### `<file_path>:<line_number>`

**Existing comment by @<author>:**
> <quote the existing comment>

**Add to discussion:**

```text
<suggested addition that builds on the existing comment>
```

*From: <Agent Name> (<confidence>% confidence)*

---

### Already Covered

List findings where existing comments are sufficient:

- `<file_path>:<line_number>` - @<author>'s comment adequately addresses <brief description>

---

### Summary

| Status | Count |
|--------|-------|
| New comments | X |
| Build upon existing | Y |
| Already covered | Z |
```

5. **Append to review file**: Add the "Suggested Comments" section after the main review content.

6. **Display summary to user**: After saving, show a brief summary:

```
Suggested Comments:
- X new comments to consider posting
- Y comments that build on existing discussion
- Z findings already covered by existing comments

See the review file for copy/paste ready comments.
```

### Create Draft Review (--draft flag)

If `--draft` was specified and this is a PR review (not own PR), create a pending GitHub review with inline comments.

**CRITICAL RULES for draft reviews:**
- The draft review contains ONLY inline comments at specific file:line locations
- The review summary should be a brief 1-2 sentence overview, NOT the full review
- The full detailed review stays in the markdown file only
- NEVER use `gh pr review` directly - always use `create-draft-review.sh`
- NEVER post the full review summary to GitHub

**Check if draft mode is enabled:**

```bash
draft_mode=$(jq -r '.draft // false' "$SESSION_FILE")
is_own_pr=$(jq -r '.is_own_pr // false' "$SESSION_FILE")
self_mode=$(jq -r '.self // false' "$SESSION_FILE")
mode=$(jq -r '.mode' "$SESSION_FILE")
```

**Only proceed if ALL conditions are true:**
- `draft_mode` is "true"
- `mode` is "pr"
- `is_own_pr` is "false" OR `self_mode` is "true"

If any condition fails, skip draft review creation.

**If conditions are met:**

1. **Extract suggested comments from the review**: Parse the "Suggested Comments" section to get:
   - File path
   - Line number
   - Comment body (without metadata like agent name/confidence)

   Look for the pattern in the review file:
   ```
   #### `<file_path>:<line_number>`
   ```text
   <comment body>
   ```
   ```

2. **Get the diff for position mapping**:

```bash
diff=$(jq -r '.diff' "$SESSION_FILE")
```

3. **Build targets for position mapping**: Create JSON with file:line targets from extracted comments.

4. **Map line numbers to diff positions**: Use the diff-position-mapper script.

```bash
echo "$mapping_input" | ~/.claude/skills/review-code/scripts/diff-position-mapper.sh
```

5. **Separate mappable vs unmappable comments**:
   - Mappable: Comments with valid diff positions (will be inline comments)
   - Unmappable: Comments where line not in diff (will go in summary)

6. **Build input for create-draft-review.sh**:

```json
{
  "owner": "<org from session>",
  "repo": "<repo from session>",
  "pr_number": <number from session>,
  "reviewer_username": "<reviewer from session>",
  "summary": "<BRIEF 1-2 sentence summary, e.g. 'Code review with 3 suggestions. See inline comments.'>",
  "comments": [
    {"path": "file.ts", "position": 23, "body": "Clean comment text"}
  ],
  "unmapped_comments": [
    {"description": "General finding that couldn't be mapped to diff"}
  ]
}
```

**IMPORTANT**: The `summary` field should be a brief overview (1-2 sentences), NOT the full review. Example: "Code review complete with 3 inline suggestions for improved error handling." The detailed findings are in the markdown file.
```

7. **Create the pending review**:

```bash
echo "$draft_input" | ~/.claude/skills/review-code/scripts/create-draft-review.sh
```

8. **Display result to user**:

If successful:
```
Draft review created on GitHub!

🔗 Review: <review_url>

Summary:
- Inline comments: X
- Summary comments: Y

{If amended}:
- Comments kept (updated wording): K
- New comments added: N
- Outdated comments removed: R

The review is in PENDING state. Visit GitHub to:
- Edit or remove any comments
- Add additional comments
- Submit with Approve/Request Changes/Comment
```

If failed, show the error and suggest using the review file manually.

**Error handling:**

- **Not PR mode**: "The --draft flag only works when reviewing a pull request"
- **Own PR**: "Cannot create draft review on your own pull request"
- **No mappable comments**: Create review with summary only, warn user
- **API failure**: Display error, suggest using review file manually

**What NOT to do:**
- ❌ Do NOT use `gh pr review` or `gh api` directly to create reviews
- ❌ Do NOT post the full review summary as the review body
- ❌ Do NOT skip the `create-draft-review.sh` script
- ✅ DO save detailed review to markdown file
- ✅ DO use `create-draft-review.sh` with brief summary + inline comments only

### Cleanup Session

After the review is complete, cleanup the session (replace `<SESSION_ID>` with the actual session ID):

```bash
bash -c '
SESSION_ID="<SESSION_ID>"
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "$SESSION_ID"
echo "Session cleaned up: $SESSION_ID"
'
```

This removes the temporary session files and frees up disk space.
