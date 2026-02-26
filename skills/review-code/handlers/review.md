## Handler: "ready"

If STATUS is "ready", get the session file path (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-session-file "<SESSION_ID>"
```

Save the output as `SESSION_FILE`. Then read the session file using the Read tool and extract `display_summary` to show the user what will be reviewed.

**All subsequent data extraction uses the Read tool on the same SESSION_FILE — no re-running the orchestrator.**

Proceed directly with the review.

**Check for existing review and branch review:**

From the session file JSON (already read above), extract these fields:
- `file_info.file_exists` — whether a review file already exists
- `file_info.file_path` — path to the existing review
- `file_info.has_branch_review` — whether both PR and branch reviews exist (defaults to false)
- `file_info.branch_review_path` — path to the branch review
- `file_info.needs_rename` — whether the branch review should migrate to PR format (defaults to false)
- `file_info.pr_number` — the associated PR number

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

**Extract the data needed for building agent context:**

From the session file JSON (already read via Read tool), extract these fields:
- `mode` — review mode (pr, branch, commit, range, local)
- `diff` — the code changes to review
- `file_metadata` — metadata about changed files
- `review_context` — language/framework-specific guidelines
- `git` — git repository context
- `languages` — detected languages
- `file_info.file_path` — where to save the review
- `file_ref` — (optional) git ref for reading PR files when on a different branch

**Extract mode-specific fields:**

- **For PR mode:** `pr` — PR details (number, title, author, body, comments, etc.); `file_ref` — git ref for file access (present when reviewing from a different branch in the same repo)
- **For branch/commit/range modes:** `branch`, `base_branch`, `commit`, `range`
- **For area-specific reviews:** `area`

### Prepare File Access Instructions

Build `$file_access_instructions` based on the review context. This block is included in both the context explorer and specialized agent prompts:

{If file_ref is set:}
```
**File Access:**
You are reviewing from a different branch in the same repo. To read files as they appear in the PR, use `git show "$file_ref:<path>"` via the Bash tool (always quote the argument to handle paths with spaces or special characters). Do NOT use `git checkout` or `git switch` — this would modify the user's working tree. The Read, Grep, and Glob tools operate on the current working tree (which may differ from the PR branch), so use them for finding patterns and conventions but not for reading the PR's file contents. `git show` works for any file that exists at the ref, including files newly added in the PR. If `git show` fails (e.g., the file was deleted or renamed, the path is wrong, or the ref was not fetched), fall back to the diff content.
```

{If file_ref is NOT set and working_dir is not null:}
```
**File Access:**
You are on the PR's branch. Use the Read tool to read files normally.
```

{If working_dir is null:}
```
**File Access:**
No local checkout available. Work from the diff content only.
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

$file_access_instructions

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

{If pr.linked_issues is not empty:}
**Linked Issues:**
{For each issue in pr.linked_issues:}
### Issue #$issue.number: $issue.title
**Labels:** $issue.labels (comma-separated names)
**State:** $issue.state
$issue.body
---
{End for}

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

$file_access_instructions

**Accuracy Requirements:**
For each finding you report:
1. Quote the exact code you're referencing
2. Verify the line number by reading the actual file (see File Access above)
3. Only flag code in the diff - do not flag pre-existing issues in unchanged code
4. For bug claims: read surrounding code to confirm the behavior before reporting
Do NOT report anything as a bug unless you've verified the behavior by reading the code.

**Comment Prefixes:**

Prefix every finding so the author knows what action is expected. The prefix must be code-formatted in the comment body (e.g., `` `blocking`: This must be fixed ``):

- `blocking` — This must be fixed before merge. Use sparingly — reserve it for bugs, security issues, or things that will break.
- `nit` — A minor style or naming suggestion. Take it or leave it.
- `suggestion` — A different approach worth considering, but the author's call.
- `question` — You don't understand something. Not necessarily a problem, but you'd like clarification.

If a comment has no prefix, assume it's a suggestion.

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
4. **Track fix status**: `Fixed in <commit>`, `Open`, or `Invalid`
5. **Summarize at the start** in a table:
   ```
   | Issue | Found By | Status | Assessment |
   |-------|----------|--------|------------|
   | N+1 query | @bot | Fixed | Valid - good catch |
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

First, check if this is frontend code by inspecting the `languages.has_frontend` field from the session data (already read via Read tool).

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

Use ultrathink to synthesize findings from all agents into a coherent, deduplicated review.

After all agents complete, combine their findings into a single review document.

**Verify findings against the diff before including them in the final review.**

After collecting findings from agents, validate that each finding references code actually in the diff. This catches wrong line numbers, findings about unrelated files, and stale references.

**Step 1: Extract and validate.** For each agent's findings that reference a specific file and line, build a targets array and run it through the position mapper:

```bash
~/.claude/skills/review-code/scripts/diff-position-mapper.sh <<'EOF'
{"diff": "<diff from session data>", "targets": [<targets array>]}
EOF
```

Where the `targets` array contains `{"path": "<file>", "line": <number>}` objects extracted from the agent findings, and `diff` is the diff string from the session data.

**Step 2: Handle results.** Check the `mappings` array in the output:

- **Has `side` field** (line is in the diff): Include the finding as-is.
- **Error: `"line not in diff"`** (file is in the diff but line is outside any hunk):
  1. Resume the agent that produced this finding (using the agent ID from the Task tool).
  2. Ask: "Your finding at `<file>:<line>` references a line outside the changed hunks in the diff. Is this finding still relevant to the changes (e.g., the issue interacts with the changed code), or should it be dropped?"
  3. Include only if the agent confirms relevance and provides justification.
- **Error: `"file not in diff"`**: Drop the finding. The file was not part of the changes.

**Step 3: Spot-check bug claims.** For any remaining finding that claims a bug or incorrect behavior, use the Read tool to verify the claim is accurate before including it.

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
Pull Request: $pr_url

Review saved to: $review_file

You can open it directly: file://$review_file
```

**CRITICAL: Do NOT post the full review to GitHub.** The detailed review is saved to the markdown file only. If `--draft` mode is enabled, a separate draft review with inline comments will be created in the next step - but that draft should contain only brief inline comments, NOT the full review summary.

### Generate Suggested Comments (PR Mode Only)

If this is a PR review and the reviewer is NOT the PR author, generate suggested inline comments for the review file. This helps the reviewer quickly identify what comments to post on the PR.

**Check if suggested comments should be generated:**

From the session data (already read via Read tool), extract:
- `is_own_pr` — whether the current user authored the PR (defaults to false)
- `pr.comments.inline` — existing inline comments on the PR (defaults to empty array)

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
- NEVER include confidence percentages in GitHub comments — confidence is internal review metadata only

**Check if draft mode is enabled:**

From the session data (already read via Read tool), extract: `draft` (defaults to false), `is_own_pr` (defaults to false), `self` (defaults to false), and `mode`.

**Only proceed if ALL conditions are true:**
- `draft_mode` is "true"
- `mode` is "pr"
- `is_own_pr` is "false" OR `self_mode` is "true"

If any condition fails, skip draft review creation.

**If conditions are met:**

1. **Extract suggested comments from the review**: Parse the "Suggested Comments" section to get:
   - File path
   - Line number
   - Comment body — extract ONLY the text inside the ` ```text ``` ` code block

   Look for the pattern in the review file:
   ```
   #### `<file_path>:<line_number>`
   ```text
   <comment body>
   ```
   ```

   **CRITICAL**: Do NOT include the `*From: <Agent Name> (<confidence>% confidence)*` metadata line in the comment body. Confidence percentages are internal review metadata only — they must never appear in public GitHub comments. Extract only what is inside the ` ```text ``` ` block.

2. **Get the diff for position mapping**: Use the `diff` field from the session data (already read via Read tool).

3. **Build targets for line mapping**: Create JSON with file:line targets from extracted comments.

4. **Map line numbers to diff lines**: Use the diff-position-mapper script.

```bash
~/.claude/skills/review-code/scripts/diff-position-mapper.sh <<'EOF'
{"diff": "<diff from session data>", "targets": [<targets from step 3>]}
EOF
```

5. **Separate mappable vs unmappable comments**:
   - Mappable: Comments with valid line mappings (will be inline comments)
   - Unmappable: Comments where line not in diff (will go in summary)

6. **Build input for create-draft-review.sh**:

```json
{
  "owner": "<org from session>",
  "repo": "<repo from session>",
  "pr_number": <number from session>,
  "reviewer_username": "<reviewer from session>",
  "summary": "<Short, conversational summary — see guidance below>",
  "comments": [
    {"path": "file.ts", "line": 42, "side": "RIGHT", "body": "Clean comment text"}
  ],
  "unmapped_comments": [
    {"description": "General finding that couldn't be mapped to diff"}
  ]
}
```

**IMPORTANT**: The `summary` field should sound like a human reviewer wrote it — warm, conversational, and specific to the PR. It follows a two-part structure:

1. **Lead with genuine appreciation.** Call out something specific you liked about the PR — a clever approach, a clean refactor, something you learned, or just good taste. Be specific; generic praise ("nice work") is worse than no praise.
2. **Briefly characterize the inline comments.** One sentence indicating whether the suggestions are blocking or non-blocking.

Good examples (match this voice):

- "Nice job! I really liked how you extracted the retry logic into its own module — much cleaner. Some suggestions inline, but nothing blocking."
- "TIL about `Intl.Segmenter` — cool find. A couple of blocking issues inline that should be fixed before approval."
- "This is a great simplification of the auth flow. LGTM, no comments."
- "Really nice test coverage here. Some suggestions inline, but nothing blocking."

Bad examples (robotic, template-sounding, or vague):

- "Code review with 3 inline suggestions. See review file for full details."
- "Code review complete with 3 inline suggestions for improved error handling."
- "Nice work! Some suggestions." (too generic — what specifically was nice?)
- "LGTM! Two non-blocking suggestions." (fine as a fallback, but try to be more specific)

The summary should NOT be the full review — it's the casual top-level comment on a GitHub review. Keep it to 1-2 sentences.

**Code Suggestions:**

When recommending a code change, use GitHub's suggestion syntax in the comment body:

````markdown
```suggestion
replacement code here
```
````

This renders as an "Apply suggestion" button that the PR author can click to commit the change.

7. **Create the pending review**:

```bash
~/.claude/skills/review-code/scripts/create-draft-review.sh <<'EOF'
<draft_input JSON here>
EOF
```

8. **Display result to user**:

If successful:
```
Draft review created on GitHub!

Review: <review_url>

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
- **API failure (HTTP 422, etc.)**:
  1. Display the error message to the user
  2. Tell them: "Draft review creation failed. The review has been saved to the markdown file."
  3. Suggest: "You can copy comments from the review file and post them manually on GitHub."
  4. **STOP HERE** - Do NOT attempt to post comments using `gh pr review` or any other method as a fallback. This will submit the review instead of keeping it pending.

**What NOT to do:**
- Do NOT use `gh pr review` or `gh api` directly to create reviews
- Do NOT post the full review summary as the review body
- Do NOT skip the `create-draft-review.sh` script
- **NEVER fall back to posting a regular comment when draft review fails** - if the API fails, STOP and tell the user. Do not try to work around the failure by posting a comment directly.
- **NEVER submit a pending review without explicit user approval** - if the user asks to add comments to a pending review and you cannot amend it, ASK the user if they want to submit the current review first. Never submit on their behalf.
- DO save detailed review to markdown file
- DO use `create-draft-review.sh` with brief summary + inline comments only
- DO stop and inform the user when errors occur - let them decide how to proceed

### Offer to Submit Review

After creating the draft review successfully, offer to submit it from within Claude Code.

**Only proceed if the draft review was created successfully** (the `create-draft-review.sh` output has `success: true` and a valid `review_id`).

Use `AskUserQuestion` with these options:

1. "Submit as Comment" — neutral feedback, no approval or rejection
2. "Submit as Approve" — approve the PR
3. "Submit as Request Changes" — request changes before merge
4. "Keep as draft" — don't submit now; visit GitHub to review and submit manually

**If the user selects one of the submit options:**

Map the selection to an event value:
- "Submit as Comment" → `COMMENT`
- "Submit as Approve" → `APPROVE`
- "Submit as Request Changes" → `REQUEST_CHANGES`

Call `submit-review.sh` with the review ID from the draft creation output:

```bash
~/.claude/skills/review-code/scripts/submit-review.sh <<'EOF'
{"owner": "<owner>", "repo": "<repo>", "pr_number": <number>, "review_id": <review_id>, "event": "<EVENT>"}
EOF
```

**Display the result:**

If successful:
```
Review submitted!

Review: <review_url>
Event: <event> (State: <state>)
```

If failed, show the error and tell the user they can submit manually on GitHub.

**If the user selects "Keep as draft":**

```
Review kept as draft. Visit GitHub to review and submit:
<review_url>
```

### Cleanup Session

After the review is complete, cleanup the session (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

This removes the temporary session files and frees up disk space.
