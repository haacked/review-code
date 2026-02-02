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

---

## Implementation

**NOTE**: Uses session-based caching to run the orchestrator once and reuse the data across multiple bash invocations. This reduces token usage by ~60%.

### Step 1: Initialize Session

Initialize the review session by running the orchestrator and caching the result:

```bash
bash -c '
SESSION_ID=$(~/.claude/bin/review-code/review-status-handler.sh init "'"$ARGUMENTS"'")
STATUS=$(~/.claude/bin/review-code/review-status-handler.sh get-status "$SESSION_ID")
echo "Session: $SESSION_ID, Status: $STATUS"
'
```

The `--force` and `-f` flags are handled automatically by the orchestrator. When present, the session data will include `"force": true`.

This creates a session and outputs the status. Based on the status, proceed to the appropriate handler below.

**IMPORTANT**: Save the `$SESSION_ID` value from the output - you'll need it for all subsequent operations.

### Handler: "error"

If STATUS is "error", get the error message from the session (replace `<SESSION_ID>` with the actual session ID):

```bash
bash -c '
SESSION_ID="<SESSION_ID>"
error_msg=$(~/.claude/bin/review-code/review-status-handler.sh get-error-data "$SESSION_ID")
echo "Error: $error_msg"
~/.claude/bin/review-code/review-status-handler.sh cleanup "$SESSION_ID"
'
```

Then stop - do not proceed with review.

### Handler: "ambiguous"

If STATUS is "ambiguous", get the disambiguation data from the session (replace `<SESSION_ID>` with the actual session ID):

```bash
bash -c '
SESSION_ID="<SESSION_ID>"
data=$(~/.claude/bin/review-code/review-status-handler.sh get-ambiguous-data "$SESSION_ID")
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
data=$(~/.claude/bin/review-code/review-status-handler.sh get-prompt-data "$SESSION_ID")
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
data=$(~/.claude/bin/review-code/review-status-handler.sh get-prompt-pull-data "$SESSION_ID")
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
find_data=$(~/.claude/bin/review-code/review-status-handler.sh get-find-data "$SESSION_ID")
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
~/.claude/bin/review-code/review-status-handler.sh cleanup "$SESSION_ID"
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

If STATUS is "ready", get all the review data from the session and display the summary (replace `<SESSION_ID>` with the actual session ID):

```bash
bash -c '
SESSION_ID="<SESSION_ID>"
review_data=$(~/.claude/bin/review-code/review-status-handler.sh get-ready-data "$SESSION_ID")
display_summary=$(echo "$review_data" | jq -r ".display_summary")
echo "$display_summary"
'
```

This displays the pre-formatted summary showing what will be reviewed.

**All subsequent operations will use the same SESSION_ID to read from the cached session data.**

**Ask user to confirm (unless --force was specified):**

Check if the `force` flag is set in the session data:

```bash
force_flag=$(echo "$review_data" | jq -r ".force // false")
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

**Check for existing review and branch review (replace `<SESSION_ID>` with the actual session ID):**

```bash
~/.claude/bin/review-code/review-status-handler.sh \
  get-ready-data <SESSION_ID> | \
  jq -r '{
    existing: (if .file_info.file_exists == true then .file_info.file_path else null end),
    has_branch_review: (.file_info.has_branch_review // false),
    branch_review_path: (.file_info.branch_review_path // null),
    needs_rename: (.file_info.needs_rename // false),
    pr_number: (.file_info.pr_number // null)
  }'
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

**Extract the data needed for building agent context (replace `<SESSION_ID>` with the actual session ID):**

All subsequent extractions use the SAME SESSION_ID (no re-running orchestrator). Save the session data to a variable for reuse:

```bash
review_data=$(~/.claude/bin/review-code/review-status-handler.sh get-ready-data <SESSION_ID>)
```

Then extract individual fields as needed using jq:
- `mode=$(echo "$review_data" | jq -r ".mode")`
- `diff=$(echo "$review_data" | jq -r ".diff")`
- `file_metadata=$(echo "$review_data" | jq -r ".file_metadata")`
- `review_context=$(echo "$review_data" | jq -r ".review_context")`
- `git_context=$(echo "$review_data" | jq -r ".git")`
- `languages=$(echo "$review_data" | jq -r ".languages")`
- `review_file=$(echo "$review_data" | jq -r ".file_info.file_path")`

**Extract mode-specific fields from the cached session (using the `$review_data` variable from above):**

Extract mode-specific fields as needed:
- **For PR mode:** `pr=$(echo "$review_data" | jq -r ".pr // empty")`
- **For branch/commit/range modes:**
  - `branch=$(echo "$review_data" | jq -r ".branch // empty")`
  - `base_branch=$(echo "$review_data" | jq -r ".base_branch // empty")`
  - `commit=$(echo "$review_data" | jq -r ".commit // empty")`
  - `range=$(echo "$review_data" | jq -r ".range // empty")`
- **For area-specific reviews:** `area=$(echo "$review_data" | jq -r ".area // empty")`

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
(using the `$review_data` variable from above):

```bash
has_frontend=$(echo "$review_data" | \
  jq -r ".languages.has_frontend // false")
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

### Generate Suggested Comments (PR Mode Only)

If this is a PR review and the reviewer is NOT the PR author, generate suggested inline comments for the review file. This helps the reviewer quickly identify what comments to post on the PR.

**Check if suggested comments should be generated:**

Extract from session data (using the `$review_data` variable):

```bash
is_own_pr=$(echo "$review_data" | jq -r '.is_own_pr // false')
inline_comments=$(echo "$review_data" | jq '.pr.comments.inline // []')
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

### Cleanup Session

After the review is complete, cleanup the session (replace `<SESSION_ID>` with the actual session ID):

```bash
bash -c '
SESSION_ID="<SESSION_ID>"
~/.claude/bin/review-code/review-status-handler.sh cleanup "$SESSION_ID"
echo "Session cleaned up: $SESSION_ID"
'
```

This removes the temporary session files and frees up disk space.
