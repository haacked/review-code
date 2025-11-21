---
description: Run specialized code review agents on code changes or pull requests
argument-hint: [pr|commit|branch|range|area]
---

Run specialized code review agent(s) with comprehensive context on local changes or pull requests.

**Arguments:**

- `<number>` - Review Pull Request by number (e.g., `123`)
- `<pr-url>` - Review Pull Request by URL (e.g., `https://github.com/org/repo/pull/123`)
- `<commit>` - Review that specific commit's changes (e.g., `356ded2`)
- `<branch>` - Review all changes in branch vs base (e.g., `feature-branch`)
- `<range>` - Review specific git range (e.g., `abc123..HEAD`, `v1.0.0..v2.0.0`)
- `security` - Deep security vulnerability analysis only (local changes)
- `performance` - Performance bottlenecks and optimization only (local changes)
- `maintainability` - Code clarity, simplicity, and maintainability only (local changes)
- `testing` - Test coverage, quality, and patterns only (local changes)
- `compatibility` - Backwards compatibility with shipped code only (local changes)
- `architecture` - High-level design, patterns, and necessity only (local changes)
- (no argument) - Run ALL 6 specialized agents in parallel on local changes (default)

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
- `/review-code 123` - Review PR #123 from current repo
- `/review-code https://github.com/PostHog/posthog/pull/41471` - Review PR by URL
- `/review-code 356ded2` - Review that specific commit
- `/review-code feature-branch` - Review all changes in branch vs main
- `/review-code abc123..HEAD` - Review changes from abc123 to HEAD
- `/review-code v1.0.0..v2.0.0` - Review changes between two tags
- `/review-code security` - Run only security review on local changes
- `/review-code maintainability` - Run only maintainability review on local changes

**With file patterns:**

- `/review-code 356ded2..HEAD "*.sh"` - Review only shell script changes in range
- `/review-code "lib/*.sh"` - Review only shell scripts in lib/ directory (local)
- `/review-code feature-branch "*.py"` - Review only Python files in branch
- `/review-code 123 "src/**/*.ts"` - Review only TypeScript files in PR #123
- `/review-code security "*.rs"` - Security review of only Rust files (local)

---

## Implementation

Call the review orchestrator to gather all context and determine what to do:

```bash
review_data=$(~/.claude/bin/review-code/review-orchestrator.sh "$ARGUMENTS") && status=$(echo "$review_data" | jq -r '.status')
```

Handle the response based on status:

### Status: "error"

Display the error and exit:

```bash
error_msg=$(echo "$review_data" | jq -r '.message') && echo "Error: $error_msg" && exit 1
```

### Status: "ambiguous"

The user provided a reference that could mean multiple things. Ask them to clarify:

```bash
arg=$(echo "$review_data" | jq -r '.arg'); ref_type=$(echo "$review_data" | jq -r '.ref_type'); is_branch=$(echo "$review_data" | jq -r '.is_branch'); is_current=$(echo "$review_data" | jq -r '.is_current'); base_branch=$(echo "$review_data" | jq -r '.base_branch'); reason=$(echo "$review_data" | jq -r '.reason')
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

### Status: "prompt"

No argument provided and we're on a feature branch with uncommitted changes. Ask user what to review:

```bash
current_branch=$(echo "$review_data" | jq -r '.current_branch'); base_branch=$(echo "$review_data" | jq -r '.base_branch'); has_uncommitted=$(echo "$review_data" | jq -r '.has_uncommitted')
```

Use AskUserQuestion:
- Question: "You're on branch '$current_branch' with uncommitted changes. What would you like to review?"
- Options:
  1. "Uncommitted only" - Review staged and unstaged files only
  2. "Branch changes" - Review all changes vs $base_branch
  3. "Comprehensive" - Review branch + uncommitted changes

After user selects, re-run orchestrator with appropriate mode.

### Status: "prompt_pull"

The remote branch is ahead of the local branch. Prompt user to pull:

```bash
branch=$(echo "$review_data" | jq -r '.branch'); associated_pr=$(echo "$review_data" | jq -r '.associated_pr // empty')
```

Use AskUserQuestion:
- Question: "Remote branch '$branch' is ahead of local. Would you like to pull changes first?"
- Options:
  1. "Pull and review" - Run `git pull` then proceed with review
  2. "Review local anyway" - Review the local branch as-is

After user selects:
- If "Pull and review": Run `git pull` then re-run orchestrator
- If "Review local anyway": Re-run orchestrator with special flag to skip remote check (TBD: implement this)

### Status: "ready"

All context has been gathered. First, extract and display the summary for user confirmation:

```bash
mode=$(echo "$review_data" | jq -r '.mode'); summary=$(echo "$review_data" | jq -r '.summary'); diff=$(echo "$review_data" | jq -r '.diff'); file_metadata=$(echo "$review_data" | jq -r '.file_metadata'); review_context=$(echo "$review_data" | jq -r '.review_context'); git_context=$(echo "$review_data" | jq -r '.git // empty'); languages=$(echo "$review_data" | jq -r '.languages // empty'); review_file=$(echo "$review_data" | jq -r '.file_info.file_path'); file_exists=$(echo "$review_data" | jq -r '.file_info.file_exists')
```

**Display the summary and get user confirmation:**

Build the summary message based on mode:

**For branch mode:**
```bash
repository=$(echo "$summary" | jq -r '.repository'); branch=$(echo "$summary" | jq -r '.branch'); base_branch=$(echo "$summary" | jq -r '.base_branch'); commit=$(echo "$summary" | jq -r '.commit // "unknown"'); working_dir=$(echo "$summary" | jq -r '.working_directory'); comparison=$(echo "$summary" | jq -r '.comparison'); commits=$(echo "$summary" | jq -r '.stats.commits // "unknown"'); files_changed=$(echo "$summary" | jq -r '.stats.files_changed'); lines_added=$(echo "$summary" | jq -r '.stats.lines_added'); lines_removed=$(echo "$summary" | jq -r '.stats.lines_removed'); has_pr=$(echo "$summary" | jq -r '.associated_pr // empty'); pr_number=$(echo "$summary" | jq -r '.associated_pr.number // empty'); pr_title=$(echo "$summary" | jq -r '.associated_pr.title // empty'); pr_url=$(echo "$summary" | jq -r '.associated_pr.url // empty'); pr_author=$(echo "$summary" | jq -r '.associated_pr.author // empty'); pr_state=$(echo "$summary" | jq -r '.associated_pr.state // empty')
```

Display (with PR if available):
```
📋 Review Summary

Repository: $repository
Branch: $branch (vs $base_branch)
Commit: ${commit:0:10}
Location: $working_dir
Comparison: $comparison

# If PR exists, display PR info:
if [ -n "$has_pr" ]; then
  echo "Associated PR: #$pr_number - $pr_title"
  echo "Author: $pr_author | State: $pr_state"
  echo "URL: $pr_url"
  echo ""
fi

Changes:
- Commits: $commits
- Files: $files_changed
- Added: +$lines_added lines
- Removed: -$lines_removed lines

Review will be saved to: $review_file
```

**For PR mode:**
```bash
repository=$(echo "$summary" | jq -r '.repository'); pr_number=$(echo "$summary" | jq -r '.pr_number'); pr_title=$(echo "$summary" | jq -r '.pr_title'); pr_url=$(echo "$summary" | jq -r '.pr_url'); branch=$(echo "$summary" | jq -r '.branch'); files_changed=$(echo "$summary" | jq -r '.stats.files_changed'); lines_added=$(echo "$summary" | jq -r '.stats.lines_added'); lines_removed=$(echo "$summary" | jq -r '.stats.lines_removed')
```

Display:
```
📋 Review Summary

Repository: $repository
PR: #$pr_number - $pr_title
URL: $pr_url
Branch: $branch

Changes:
- Files: $files_changed
- Added: +$lines_added lines
- Removed: -$lines_removed lines

Review will be saved to: $review_file
```

**For commit mode:**
```bash
repository=$(echo "$summary" | jq -r '.repository'); commit=$(echo "$summary" | jq -r '.commit'); working_dir=$(echo "$summary" | jq -r '.working_directory'); files_changed=$(echo "$summary" | jq -r '.stats.files_changed'); lines_added=$(echo "$summary" | jq -r '.stats.lines_added'); lines_removed=$(echo "$summary" | jq -r '.stats.lines_removed')
```

Display:
```
📋 Review Summary

Repository: $repository
Commit: $commit
Location: $working_dir

Changes:
- Files: $files_changed
- Added: +$lines_added lines
- Removed: -$lines_removed lines

Review will be saved to: $review_file
```

**For range mode:**
```bash
repository=$(echo "$summary" | jq -r '.repository'); range=$(echo "$summary" | jq -r '.range'); working_dir=$(echo "$summary" | jq -r '.working_directory'); commits=$(echo "$summary" | jq -r '.stats.commits // "unknown"'); files_changed=$(echo "$summary" | jq -r '.stats.files_changed'); lines_added=$(echo "$summary" | jq -r '.stats.lines_added'); lines_removed=$(echo "$summary" | jq -r '.stats.lines_removed')
```

Display:
```
📋 Review Summary

Repository: $repository
Range: $range
Location: $working_dir

Changes:
- Commits: $commits
- Files: $files_changed
- Added: +$lines_added lines
- Removed: -$lines_removed lines

Review will be saved to: $review_file
```

**For local mode:**
```bash
repository=$(echo "$summary" | jq -r '.repository'); branch=$(echo "$summary" | jq -r '.branch'); working_dir=$(echo "$summary" | jq -r '.working_directory'); review_area=$(echo "$summary" | jq -r '.review_area // "all"'); files_changed=$(echo "$summary" | jq -r '.stats.files_changed'); lines_added=$(echo "$summary" | jq -r '.stats.lines_added'); lines_removed=$(echo "$summary" | jq -r '.stats.lines_removed')
```

Display:
```
📋 Review Summary

Repository: $repository
Branch: $branch (uncommitted changes)
Location: $working_dir
Review Area: $review_area

Changes:
- Files: $files_changed
- Added: +$lines_added lines
- Removed: -$lines_removed lines

Review will be saved to: $review_file
```

**Ask user to confirm:**

Use AskUserQuestion:
- Question: "Proceed with code review of these changes?"
- Options:
  1. "Yes, review these changes" - Proceed with the review
     Description: "Run comprehensive code review agents on the changes above"
  2. "Cancel" - Exit without reviewing
     Description: "Stop and return without running review"

If user selects "Cancel", exit without proceeding.

If user selects "Yes, review these changes", continue with the review below.

**Check for existing review:**

```bash
if [ "$file_exists" = "true" ] && [ -f "$review_file" ]; then echo "existing"; else echo "none"; fi
```

If existing review found, use AskUserQuestion:
- Question: "An existing review was found at:\n\n$review_file\n\nWhat would you like to do?"
- Options:
  1. "Continue review" - Build upon the existing review (recommended)
     Description: "Adds new findings to existing review, references previous work"
  2. "Start fresh" - Create a new review from scratch
     Description: "Backs up old review and creates a new one"
  3. "View existing" - Show the current review without changes
     Description: "Read the existing review file"

Based on user selection:
- If "Continue review": Load previous review:
  ```bash
  previous_review=$(cat "$review_file")
  ```
- If "Start fresh": Backup and reset:
  ```bash
  cp "$review_file" "${review_file}.bak" && echo "Backed up previous review to: ${review_file}.bak" && previous_review=""
  ```
- If "View existing": Show and exit:
  ```bash
  cat "$review_file"
  ```
  Then return without running review.
- If no existing review:
  ```bash
  previous_review=""
  ```

**For PR mode**, also extract:
```bash
pr=$(echo "$review_data" | jq -r '.pr'); pr_number=$(echo "$pr" | jq -r '.number'); pr_title=$(echo "$pr" | jq -r '.title'); pr_url=$(echo "$pr" | jq -r '.url'); pr_author=$(echo "$pr" | jq -r '.author'); pr_body=$(echo "$pr" | jq -r '.body'); pr_comments=$(echo "$pr" | jq -r '.comments')
```

**For commit/branch/range modes**, extract identifier:
```bash
commit=$(echo "$review_data" | jq -r '.commit // empty'); branch=$(echo "$review_data" | jq -r '.branch // empty'); base_branch=$(echo "$review_data" | jq -r '.base_branch // empty'); range=$(echo "$review_data" | jq -r '.range // empty')
```

**For branch mode with associated PR**, also extract PR context:
```bash
pr=$(echo "$review_data" | jq -r '.pr // empty')
if [ -n "$pr" ] && [ "$pr" != "null" ]; then
  pr_number=$(echo "$pr" | jq -r '.number')
  pr_title=$(echo "$pr" | jq -r '.title')
  pr_url=$(echo "$pr" | jq -r '.url')
  pr_author=$(echo "$pr" | jq -r '.author')
  pr_state=$(echo "$pr" | jq -r '.state')
  pr_body=$(echo "$pr" | jq -r '.body')
  pr_comments=$(echo "$pr" | jq -r '.comments')
fi
```

**For area-specific reviews**, extract:
```bash
area=$(echo "$review_data" | jq -r '.area // empty')
```

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

**Determine which agents to invoke:**

**If area is "security"**: Invoke ONLY `code-reviewer-security` agent with the context
**If area is "performance"**: Invoke ONLY `code-reviewer-performance` agent with the context
**If area is "maintainability"**: Invoke ONLY `code-reviewer-maintainability` agent with the context
**If area is "testing"**: Invoke ONLY `code-reviewer-testing` agent with the context
**If area is "compatibility"**: Invoke ONLY `code-reviewer-compatibility` agent with the context
**If area is "architecture"**: Invoke ONLY `code-reviewer-architecture` agent with the context

**If no area specified (comprehensive review)**:

First, check if this is frontend code by inspecting the languages data:
```bash
has_frontend=$(echo "$languages" | jq -r '.has_frontend // false')
```

**Always invoke these 6 core agents in PARALLEL:**
1. `code-reviewer-security` - Focus: vulnerabilities, exploits, security hardening
2. `code-reviewer-performance` - Focus: bottlenecks, inefficiencies, optimization
3. `code-reviewer-maintainability` - Focus: readability, simplicity, long-term code health
4. `code-reviewer-testing` - Focus: test coverage, quality, edge cases
5. `code-reviewer-compatibility` - Focus: backwards compatibility with shipped code
6. `code-reviewer-architecture` - Focus: necessity, patterns, code reuse, simplicity

**If `has_frontend` is true**, also invoke in the same parallel batch:
7. `code-reviewer` - With additional context: "Focus on frontend-specific concerns: React/TypeScript patterns, component design, state management, accessibility, performance, and user experience. Supplement the specialized reviews with frontend-specific insights."

All agents receive the same context but focus on their specific area.

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
