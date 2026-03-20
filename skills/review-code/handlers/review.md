## Handler: "ready"

If STATUS is "ready", get the session file path (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-session-file "<SESSION_ID>"
```

Save the output as `SESSION_FILE`. Read the session file using the Read tool and extract `display_summary` to show the user what will be reviewed.

**All subsequent data extraction uses the Read tool on the same SESSION_FILE. Do not re-run the orchestrator.**

### Handle Existing Review Files

From the session file JSON, extract:
- `file_info.file_exists`: whether a review file already exists
- `file_info.file_path`: path to the existing review
- `file_info.has_branch_review`: whether both PR and branch reviews exist (defaults to false)
- `file_info.branch_review_path`: path to the branch review
- `file_info.needs_rename`: whether the branch review should migrate to PR format (defaults to false)
- `file_info.pr_number`: the associated PR number

**If `has_branch_review` is true** (both PR and branch reviews exist):

Use AskUserQuestion:
- Question: "A branch review exists alongside the PR review. Merge before proceeding?"
- Options:
  1. "Merge and continue": Merge branch review into PR review, then proceed
  2. "Continue without merging": Keep both files, proceed
  3. "Cancel": Stop and handle manually

If user selects "Merge and continue":
1. Read both files using the Read tool
2. Append branch review content to PR review with separator: `\n\n---\n\n## Previous Branch Review\n\n`
3. Write merged content to PR review file
4. Delete branch review file: `rm "$branch_review_path"`

**If `needs_rename` is true** (branch review exists but should migrate to PR format):

Use AskUserQuestion:
- Question: "A PR (#$pr_number) exists. Migrate branch review to PR format before proceeding?"
- Options:
  1. "Migrate and continue": Rename to PR format, then proceed
  2. "Continue as branch review": Keep current format, proceed
  3. "Cancel": Stop and handle manually

If user selects "Migrate and continue":
1. Compute new path with `pr-$pr_number.md` filename
2. Move file: `mv "$file_path" "$new_path"`
3. Update `review_file` variable to new path

**If `file_info.file_exists` is true** (a review file exists but neither of the above conditions apply):

Use AskUserQuestion to ask what to do with the existing review:
- Options:
  1. "Overwrite": Replace the existing review
  2. "Append": Add new findings to the existing review
  3. "Cancel": Stop without reviewing

### Extract Session Data

From the session file JSON, extract these fields for building agent context:
- `mode`: review mode (pr, branch, commit, range, local)
- `diff`: the code changes to review
- `file_metadata`: metadata about changed files
- `review_context`: language/framework-specific guidelines
- `git`: git repository context
- `languages`: detected languages
- `file_info.file_path`: where to save the review
- `file_ref`: (optional) git ref for reading PR files when on a different branch
- `chunks`: (optional) array of chunk objects when the diff was split
- `chunk_metadata`: (optional) object with `chunked`, `reason`, `chunk_count`
- `debug_session_dir`: (optional) path to debug session directory when debug mode is enabled

### Debug Mode Setup

Extract `debug_session_dir` from the session JSON. If it is a non-empty string, debug mode is active for this review. Store it as `$debug_session_dir`.

When `$debug_session_dir` is set, write debug artifacts at key stages by calling the bridge script. Each write is a single Bash call. Debug writes must never block or fail the review: if a write fails, ignore the error and continue.

**Helper pattern for debug writes:**

To save content:
```bash
echo '{"action":"save","debug_dir":"$debug_session_dir","stage":"<stage>","filename":"<name>","content":"<text>"}' | ~/.claude/skills/review-code/scripts/debug-artifact-writer.sh
```

To record timing:
```bash
echo '{"action":"time","debug_dir":"$debug_session_dir","stage":"<stage>","event":"start"}' | ~/.claude/skills/review-code/scripts/debug-artifact-writer.sh
```

To write stats:
```bash
echo '{"action":"stats","debug_dir":"$debug_session_dir","stage":"<stage>","data":{"key":"value"}}' | ~/.claude/skills/review-code/scripts/debug-artifact-writer.sh
```

For content with special characters (quotes, newlines), use jq to build the JSON safely:
```bash
jq -n --arg dir "$debug_session_dir" --arg content "$variable_with_content" \
  '{"action":"save","debug_dir":$dir,"stage":"08-context-explorer","filename":"result.md","content":$content}' \
  | ~/.claude/skills/review-code/scripts/debug-artifact-writer.sh
```

**Stages to instrument (when `$debug_session_dir` is set):**

- **08-context-explorer**: Record timing (start/end). Save the explorer prompt as `prompt.md` and the result (`$architectural_context`) as `result.md`.
- **09-per-chunk-analysis** (chunked reviews only): Record timing (start/end). For each chunk, save the prompt as `chunk-{id}-prompt.md` and result as `chunk-{id}-result.md`.
- **10-agent-dispatch**: Record timing (start/end). For each agent (or chunk x agent combination), save the prompt as `{agent}-prompt.md` (or `chunk-{id}-{agent}-prompt.md`) and result as `{agent}-result.md` (or `chunk-{id}-{agent}-result.md`). Save stats with agent count.
- **11-synthesis**: Record timing (start/end). Save the merged findings as `merged-findings.md` and corroboration results as `corroboration.md`.

**Check for chunked diff:**

If `chunk_metadata` exists and `chunk_metadata.chunked` is `true`, set `is_chunked = true`. Extract `chunk_count` from `chunk_metadata.chunk_count` and the `chunks` array. Display to the user:

"This is a large PR ({chunk_metadata.reason}). Splitting into {chunk_count} chunks for focused review."

Mode-specific fields:
- **PR mode:** `pr`: PR details (number, title, author, body, comments, etc.); `file_ref`: git ref for file access (present when reviewing from a different branch)
- **Branch/commit/range modes:** `branch`, `base_branch`, `commit`, `range`
- **Area-specific reviews:** `area`

### Prepare File Access Instructions

Build `$file_access_instructions` based on the session data. This block is included in both the context explorer and agent prompts.

**If `file_ref` is set:**
```
**File Access:**
You are reviewing from a different branch in the same repo. To read files as they appear in the PR, use `git show "$file_ref:<path>"` via the Bash tool (always quote the argument to handle paths with spaces or special characters). Do NOT use `git checkout` or `git switch`: this would modify the user's working tree. The Read, Grep, and Glob tools operate on the current working tree (which may differ from the PR branch), so use them for finding patterns and conventions but not for reading the PR's file contents. `git show` works for any file that exists at the ref, including files newly added in the PR. If `git show` fails (e.g., the file was deleted or renamed, the path is wrong, or the ref was not fetched), fall back to the diff content.
```

**If `file_ref` is NOT set and `working_dir` is not null:**
```
**File Access:**
You are on the PR's branch. Use the Read tool to read files normally.
```

**If `working_dir` is null:**
```
**File Access:**
No local checkout available. Work from the diff content only.
```

### Gather Architectural Context

Before invoking specialized agents, use the context explorer to understand the codebase.

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
- Callers of modified functions (who calls the changed code and might be affected?)
  (grep for function/method names, report top 3-5 callers per significantly modified function)
- Existing patterns for similar functionality
- Reusable utilities or conventions

Time-box yourself to 2-3 minutes of exploration.
```

Save the explorer's output as `$architectural_context`.

### Invoke Specialized Review Agents

Invoke the appropriate agent(s) based on mode and area. If an area is specified, invoke only that agent. Otherwise, invoke all 7 core agents in parallel (plus the frontend agent if `languages.has_frontend` is true).

**Agent selection:**

| Area | `subagent_type` | Focus |
|------|----------------|-------|
| security | code-reviewer-security | Vulnerabilities, exploits, security hardening |
| performance | code-reviewer-performance | Bottlenecks, inefficiencies, optimization |
| correctness | code-reviewer-correctness | Intent verification, integration boundaries |
| maintainability | code-reviewer-maintainability | Readability, simplicity, long-term code health |
| testing | code-reviewer-testing | Test coverage, quality, edge cases |
| compatibility | code-reviewer-compatibility | Backwards compatibility with shipped code |
| architecture | code-reviewer-architecture | Necessity, patterns, code reuse, simplicity, solution proportionality |
| *(frontend detected)* | code-reviewer-frontend | React/TS patterns, components, state, a11y |

**Build the context to pass to each agent:**

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
3. Only flag code in the diff. Do not flag pre-existing issues in unchanged code.
4. For bug claims: read surrounding code to confirm the behavior before reporting
5. For every `blocking:` or `suggestion:` finding, include a **concrete code fix**: show the recommended change as a diff (`- old` / `+ new`) or replacement code block. If you cannot provide a concrete fix, demote the finding to `question:`.

Do NOT report anything as a bug unless you've verified the behavior by reading the code.

**Comment Prefixes:**

Prefix every finding so the author knows what action is expected. The prefix must be code-formatted in the comment body (e.g., `` `blocking`: This must be fixed ``):

- `blocking`: Must be fixed before merge. Reserve for bugs, security issues, or breakage.
- `nit`: Minor style or naming suggestion. Take it or leave it.
- `suggestion`: A different approach worth considering, but the author's call.
- `question`: You don't understand something. Not necessarily a problem.

If a comment has no prefix, treat it as a suggestion.

**Inline Comment Voice:**

Write comments the way a senior engineer talks in a PR review: direct, specific, and conversational. No filler, no formality, no structured headers.

- No `**Issue**:` / `**Impact**:` / `**Recommendation**:` headers. Start with the prefix, then flow into natural prose.
- Be specific: name the function, quote the value, cite the line.
- For `blocking:` and `suggestion:` findings, always include a concrete code fix (see Accuracy Requirements above). For `question:` and `nit:`, offer code when it helps. Use GitHub's `suggestion` syntax for single-line fixes.
- Defer to the author on judgment calls: "your call", "worth considering", "that said".
- Express uncertainty honestly: "Unless I'm missing something", "If I'm reading this right". Give the author the benefit of the doubt.
- Never use em dashes. Use commas, parentheses, colons, or separate sentences instead.
- Never restate what the code obviously does. The author wrote it; they know.

Good:
```
`suggestion`: The `except` clause doesn't catch `OverflowError`, which `dateutil.parser.parse()` raises for very large numeric strings like `"9999999999"`. This causes a 500 instead of a clean 400.

More broadly, consider using the existing `determine_parsed_date_for_property_matching` from `posthog/queries/base.py` instead of reimplementing the same two-step parsing here. It already catches broader exceptions and is the established pattern in the feature flag API.
```

```
`suggestion`: Unless I'm missing something, this change means `process_batch` will now retry on *all* errors, not just transient ones. That could mask permanent failures and delay error reporting to the caller.
```

Bad:
```
**Issue**: The `except` clause doesn't catch `OverflowError`.
**Impact**: This causes a 500 Internal Server Error for large numeric strings.
**Recommendation**: Add `OverflowError` to the except tuple.
```

**Handling Existing PR Comments:**

When the context includes PR comments (`$pr_comments`):
1. **Never claim credit** for issues already identified by other reviewers
2. **Evaluate each finding**: Is it legitimate? Correct? A false positive?
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

{If previous_review exists:}
**Previous Review:**
$previous_review

IMPORTANT: Build upon the previous review. Do not duplicate findings. You may:
- Reference previous findings: "As noted in the previous review..."
- Add new findings discovered since last review
- Update status if code changed
- Mark findings as resolved if fixed

### Collect and Synthesize Results
**Chunked review dispatch:**

If `is_chunked` is true:

1. **Per-chunk analysis:**

   Before dispatching review agents for chunks, run a quick analysis per chunk in parallel:

   For each chunk in the `chunks` array, invoke the Task tool with subagent_type "Explore" (all chunks in parallel):

   ```markdown
   Analyze this chunk of a larger PR to understand its purpose and implementation details.

   **PR:** #$pr_number - $pr_title
   **Chunk:** $chunk.id of $chunk_count: $chunk.label
   **Files:** $chunk.files

   **File Metadata:**
   $file_metadata

   **Diff for this chunk:**
   $chunk.diff

   $file_access_instructions

   **Context from full-diff analysis (already gathered):**
   $architectural_context

   Build on this context. Focus on chunk-specific details not covered above.

   Provide a brief (2-3 paragraph) summary covering:
   1. What this chunk accomplishes and how it fits the PR's overall goal
   2. Chunk-specific implementation details: data flow, error handling, edge cases
   3. Integration points with other system components

   Time-box to 1-2 minutes of exploration.
   ```

   Save each chunk's analysis result as `$chunk_analyses[$chunk.id]`.

2. After all per-chunk analyses complete, for each chunk in the `chunks` array, for each applicable agent:
   - Replace `$diff` in the agent context with the chunk's `diff` field (the subset of changes for this chunk)
   - Add a chunk context header to each agent prompt:
     ```
     **Chunk Context:**
     You are reviewing chunk $chunk.id of $chunk_count: $chunk.label
     Files in this chunk: $chunk.files (comma-separated list)
     Other chunks cover: (list labels of other chunks)
     If you notice issues that may interact with code in other chunks, flag them as questions.
     ```
   - Add the per-chunk analysis to each agent prompt:
     ```
     **Chunk Analysis:**
     $chunk_analyses[$chunk.id]
     ```
   - Keep all other context the same: full `file_metadata`, full `architectural_context`, full `review_context`, all PR metadata
   - Dispatch all (chunk x agent) combinations in parallel via the Task tool

3. After all tasks complete, merge all findings into a single pool for synthesis.

If `is_chunked` is false (or `chunk_metadata` is absent), behavior is identical to the non-chunked path above.

**Pre-synthesis scope filter**

After all agent results are collected (including all chunks in chunked mode), apply this filter before synthesis:

1. **Build the in-scope file list.** Extract the set of file paths present in `file_metadata`. These are the only files the PR touches.

2. **For each finding, check whether it is located at a specific file.** A finding has a specific file location if it names a path as the target of the issue (e.g., `` `src/api/views.py:42` ``, a section header like `#### src/api/views.py`, or an explicit `path:` field). Passing mentions of a filename inside prose (e.g., "This pattern is also used in `utils/helpers.py`") do not count.

3. **Apply the rule:**
   - Finding is located at a file **in** `file_metadata`: keep it.
   - Finding is located at a file **not in** `file_metadata`: drop it silently.
   - Finding has **no specific file location** (e.g., a general architectural observation): keep it.

This filter reduces noise before the expensive extended-thinking synthesis step. Line-level precision is handled later by the "Validate Findings Against the Diff" step.

Synthesize the remaining findings using extended thinking into a coherent, deduplicated review document. Apply confidence-based filtering and cross-agent corroboration before producing the final output.

**Cross-agent corroboration:** Two findings are corroborated if they reference the same file within 10 lines, or the same logical concern in the same function.

**Filtering rules:**
- **Corroborated (2+ agents or chunks):** Keep even if individual confidence is below 40%. Note as corroborated in the review.
- **Solo finding, confidence >= 40%:** Include as-is.
- **Solo finding, confidence < 40%:** Drop silently.
- **Questions and nits:** Exempt from filtering. Include regardless of confidence.
- When consolidating corroborated findings, merge into a single entry crediting all contributing agents, using the highest confidence value.

**Priority ordering in the final review:**
1. Corroborated blocking findings
2. Solo blocking findings (>= 70% confidence)
3. Corroborated suggestions
4. Solo suggestions (>= 40% confidence)
5. Questions and nits

**Important:** The final review document does NOT separate findings by chunk. Present a unified review organized by the priority ordering above, the same as for non-chunked reviews.

### Validate Findings Against the Diff

Before including any finding in the final review, verify it references code actually in the diff (across all chunks if chunked). This catches wrong line numbers, findings about unrelated files, and stale references.

**Important:** Always use the FULL diff from the session data (not chunk diffs) for position mapping. The position mapper needs the complete diff to map findings to correct GitHub inline comment positions.
**Step 1: Run the position mapper.** For each agent finding that references a specific file and line, build a targets array and run:

```bash
~/.claude/skills/review-code/scripts/diff-position-mapper.sh <<'EOF'
{"diff": "<diff from session data>", "targets": [<targets array>]}
EOF
```

Where `targets` contains `{"path": "<file>", "line": <number>}` objects, and `diff` is the diff string from the session data.

**Step 2: Handle results.** Check the `mappings` array in the output:

- **Has `side` field** (line is in the diff): Include the finding as-is.
- **Error: `"line not in diff"`** (file is in the diff but line is outside any hunk):
  1. Resume the agent that produced this finding (using the agent ID from the Task tool).
  2. Ask: "Your finding at `<file>:<line>` references a line outside the changed hunks in the diff. Is this finding still relevant to the changes (e.g., the issue interacts with the changed code), or should it be dropped?"
  3. Include only if the agent confirms relevance and provides justification.
- **Error: `"file not in diff"`**: Drop the finding silently. The pre-synthesis scope filter is the primary gate for this; the position mapper serves as a backstop for any that slip through.

**Step 3: Spot-check bug claims.** For any remaining finding that claims a bug or incorrect behavior, use the Read tool to verify the claim is accurate before including it.

### Compose the Review Document

**Title by mode:**

| Mode | Title format |
|------|-------------|
| PR | `Pull Request Review: #$pr_number - $pr_title` |
| Commit | `Commit Review: $commit` |
| Branch | `Branch Review: $branch vs $base_branch` |
| Range | `Range Review: $range` |
| Local | `Code Review: (org/repo) - (branch) (uncommitted)` |

**For comprehensive reviews**, include a section for each area:
- Security Review
- Performance Review
- Correctness Review
- Maintainability Review
- Testing Review
- Compatibility Review
- Architecture Review

**For area-specific reviews**, include only that area's findings.

If `is_chunked` is true, add a "Review Scope" note at the top of the review document (after the metadata header):

```markdown
> **Review Scope:** This review covered $chunk_count chunks ($total_file_count files total).
```

Include the metadata header at the top of the file:

```html
<!-- review-metadata
reviewed_at: <current ISO 8601 timestamp>
mode: <mode>
pr_number: <pr_number if applicable>
org: <org>
repo: <repo>
review_commit: <pr.head_sha if PR mode, omit otherwise>
-->
```

This metadata is used by the learning system to determine when the review was created. The `review_commit` field records the PR's HEAD SHA at review time, enabling drift detection when creating draft reviews later.
Save the complete review to `$review_file` and inform the user with a clickable file link:

```
Review complete!

{If PR mode:}
Pull Request: $pr_url

Review saved to: $review_file

You can open it directly: file://$review_file
```

**Do NOT post the full review to GitHub.** The detailed review is saved to the markdown file only. If `--draft` mode is enabled, a separate draft review with inline comments will be created in the next step. That draft contains only brief inline comments, not the full review summary.

### Generate Suggested Comments (PR Mode Only)

If this is a PR review and `is_own_pr` is false, generate suggested inline comments for the review file.

From the session data, extract:
- `is_own_pr`: whether the current user authored the PR (defaults to false)
- `pr.comments.inline`: existing inline comments on the PR (defaults to empty array)

**If `is_own_pr` is false:**

When combining agent findings into the review document, add a "Suggested Comments" section:

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
<comment text: direct, specific, conversational (see Inline Comment Voice above)>
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

6. **Display summary to user**: After saving, show:

```
Suggested Comments:
- X new comments to consider posting
- Y comments that build on existing discussion
- Z findings already covered by existing comments

See the review file for copy/paste ready comments.
```

### Create Draft Review (--draft flag)

If `--draft` was specified and this is a PR review (not own PR), create a pending GitHub review with inline comments.

**Rules for draft reviews:**
- The draft contains ONLY inline comments at specific file:line locations
- The review summary is a brief 1-2 sentence overview, not the full review
- The full detailed review stays in the markdown file only
- NEVER use `gh pr review` directly. Always use `create-draft-review.sh`
- NEVER include confidence percentages in GitHub comments. Confidence is internal metadata only

From the session data, extract: `draft` (defaults to false), `is_own_pr` (defaults to false), `self` (defaults to false), and `mode`.

**Only proceed if ALL conditions are true:**
- `draft_mode` is "true"
- `mode` is "pr"
- `is_own_pr` is "false" OR `self_mode` is "true"

If any condition fails, skip draft review creation.

**If conditions are met:**

1. **Extract suggested comments from the review**: Parse the "Suggested Comments" section to get file path, line number, and comment body. Extract ONLY the text inside the ` ```text ``` ` code block. Do NOT include the `*From: <Agent Name> (<confidence>% confidence)*` line. Confidence percentages are internal metadata and must never appear in GitHub comments.

   Look for this pattern in the review file:
   ```
   #### `<file_path>:<line_number>`
   ```text
   <comment body>
   ```
   ```

2. **Map comment locations to diff positions**: Build a targets array and run through the position mapper:

```bash
~/.claude/skills/review-code/scripts/diff-position-mapper.sh <<'EOF'
{"diff": "<diff from session data>", "targets": [<targets array>]}
EOF
```

3. **Separate mappable vs unmappable comments**:
   - Mappable: Comments with valid line mappings (will be inline comments)
   - Unmappable: Comments where line not in diff (will go in summary)

4. **Build input for create-draft-review.sh**:

```json
{
  "owner": "<org from session>",
  "repo": "<repo from session>",
  "pr_number": <number from session>,
  "reviewer_username": "<reviewer from session>",
  "review_commit": "<pr.head_sha from session, if available>",
  "original_diff": "<diff from session data>",
  "summary": "<Short, conversational summary (see guidance below)>",
  "comments": [
    {"path": "file.ts", "line": 42, "side": "RIGHT", "body": "Clean comment text", "line_content": "    the_actual_code()"}
  ],
  "unmapped_comments": [
    {"description": "General finding that couldn't be mapped to diff"}
  ]
}
```

**Comment drift detection:** When `review_commit` is provided, `create-draft-review.sh` automatically detects if the PR received new commits since the review was generated. If comments have drifted, it remaps them to their correct positions using content-based matching. Comments that cannot be remapped are moved to `unmapped_comments`.

**Extracting `line_content`:** For each comment, extract the code at the target file:line from the diff. Find the file in the diff, locate the target line number within the hunks, and use the code text at that line (without the `+`/`-`/` ` prefix). This enables content-based matching for drift detection.

**Writing the summary:** The `summary` field is the casual top-level comment on a GitHub review. Keep it to 1-2 short sentences. The author knows what their PR does, so never restate or narrate the approach back to them.

Default to short. Most PRs deserve a simple "LGTM!", "Nice fix!", or "Looks good!" with a note about inline comments if any. Only elaborate when something genuinely surprised you.

Good examples:
- "LGTM!"
- "Nice fix! A couple non-blocking suggestions inline."
- "Looks good, one blocking issue inline."
- "TIL about `Intl.Segmenter`, cool find. A couple suggestions inline."

Bad examples (robotic, narrating the approach, or over-explaining):
- "Code review with 3 inline suggestions. See review file for full details."
- "Nice fix for a real validation gap. The two-phase approach (relative date regex first, then dateutil) is clean." (narrates the approach)
- "I really liked how you extracted the retry logic into its own module, much cleaner." (restates what the PR does)

**Code Suggestions:**

When recommending a code change, use GitHub's suggestion syntax in the comment body:

````markdown
```suggestion
replacement code here
```
````

This renders as an "Apply suggestion" button the PR author can click to commit the change.

5. **Create the pending review**:

```bash
~/.claude/skills/review-code/scripts/create-draft-review.sh <<'EOF'
<draft_input JSON here>
EOF
```

6. **Display result to user**:

If successful:
```
Draft review created on GitHub!

Review: <review_url>

Summary:
- Inline comments: X
- Summary comments: Y
{If drift_detected is true:}
- Note: PR received new commits since review. Comments were adjusted to match current diff.

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
  4. **STOP HERE.** Do NOT attempt to post comments using `gh pr review` or any other method as a fallback. This will submit the review instead of keeping it pending.

### Offer to Submit Review

After creating the draft review successfully, offer to submit it from within Claude Code.

Only proceed if the draft review was created successfully (the `create-draft-review.sh` output has `success: true` and a valid `review_id`).

Use `AskUserQuestion` with these options:

1. "Submit as Comment": neutral feedback, no approval or rejection
2. "Submit as Approve": approve the PR
3. "Submit as Request Changes": request changes before merge
4. "Keep as draft": don't submit now; visit GitHub to review and submit manually

**If the user selects a submit option:**

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

After the review is complete, clean up the session (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

This removes the temporary session files and frees up disk space.
