## PR Output

Loaded when `mode` is `"pr"`. These steps produce the PR-specific outputs. They run at two points in the review flow:

- "Link File References in Comment Bodies" runs immediately after the Voice Pass (before the fix pass and document composition).
- "Generate Suggested Comments", "Create Draft Review", and "Resolve Addressed Threads" run in order after the "Log Token Usage" step, before "Cleanup Session".

### Link File References in Comment Bodies

Run this only when `owner`, `repo`, and `pr.head_sha` are all present in session data. Local, branch, commit, range, and area reviews have no GitHub blob URL to build, so they skip this step and leave references as plain `path:line` text.

Run it as the final body-formatting step, after the Voice Pass. The voice agent preserves `path:line` tokens exactly and its preservation check expects them in plain form, so linkify only once that check has run. Apply the rewrite in place to each surviving finding's `description` (and to any unmapped-comment text). The same linkified bodies feed both the review file's Suggested Comments and the `--draft` comments, so doing it once here covers both.

When a comment body cites a file and line **other than the comment's own anchor location**, render the citation as a GitHub permalink. GitHub renders markdown in review comment bodies and in the review summary, so a permalink lets the reader jump straight to the cited line.

Build the URL from session data:

```
https://github.com/<owner>/<repo>/blob/<pr.head_sha>/<repo_root_path>#L<line>
```

- For a line range, use `#L<start>-L<end>`.
- `<repo_root_path>` is the path from the repository root, exactly as it appears in the diff. Never a relative or truncated path.
- `<pr.head_sha>` is the full commit SHA the review ran against. Pinning to it keeps the anchor on the right line after later pushes.

Prefer a descriptive anchor over a bare path. Turn:

> … this cache is defined as `HyperCache(namespace="team_metadata")` (team_llm_gateway_policy_cache.py:91), so the gauges emit `namespace="team_metadata"`.

into:

> … this cache is defined as [`HyperCache(namespace="team_metadata")`](https://github.com/PostHog/posthog/blob/abc123def/products/llm_analytics/backend/team_llm_gateway_policy_cache.py#L91), so the gauges emit `namespace="team_metadata"`.

When the citation supports a plain-English behavioral claim, anchor the permalink on the claim's key phrase rather than a quoted code token:

> … now hits [the rule that blocks group aggregation on flags linked to an Early Access Feature](https://github.com/PostHog/posthog/blob/abc123def/products/feature_flags/backend/api/feature_flag.py#L1367) and returns a 400.

When no natural phrase fits, link the citation text itself: `[team_llm_gateway_policy_cache.py:91](<url>)`.

Do not link:
- The comment's own anchor line. The comment already sits there, so a self-link is noise.
- Backtick-quoted identifiers, type names, or values that don't point at a location (`OverflowError`, `distinct_id`).
- Paths outside the repository (third-party packages, stdlib).

### Generate Suggested Comments

If this is a PR review and `is_own_pr` is false, generate suggested inline comments for the review file.

From the session data, extract:
- `is_own_pr`: whether the current user authored the PR (defaults to false)
- `pr.comments.inline`: existing inline comments on the PR (defaults to empty array)

**If `is_own_pr` is false:**

When combining agent findings into the review document, add a "Suggested Comments" section:

1. **Extract findings with locations**: From each agent's output, identify findings that have a specific file path and line number.

   Comment bodies already have their in-prose file:line citations rendered as GitHub permalinks (see "Link File References in Comment Bodies" above). Keep those links intact when writing the bodies into the review file.

   Bodies must also already carry the seam structure (see "Break at the seam" under Inline Comment Voice in `review.md`) before they're written into the review file; preserve their paragraph breaks, never flatten a body into one block.

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
<comment text: direct, specific, conversational (see Inline Comment Voice in review.md)>
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

5. **Append to review file**: Add the "Suggested Comments" section after the main review content. On the `delta` path it goes into the append file instead, alongside the rest of what this run composed (see `review-carry-forward.md`).

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
- The draft contains only inline comments at specific file:line locations
- The review summary is a brief 1-2 sentence overview; the full detailed review stays in the markdown file only
- All draft creation goes through `create-draft-review.sh` (see the error handling below for why)

From the session data, extract: `draft` (defaults to false), `is_own_pr` (defaults to false), `self` (defaults to false), and `mode`.

**Only proceed if ALL conditions are true:**
- `draft_mode` is "true"
- `mode` is "pr"
- `is_own_pr` is "false" OR `self_mode` is "true"

If any condition fails, skip draft review creation.

**If conditions are met:**

1. **Extract suggested comments from the review**: Parse the "Suggested Comments" section to get file path, line number, and comment body. Extract only the text inside the ` ```text ``` ` code block; the `*From: <Agent Name> (<confidence>% confidence)*` line is internal metadata and never goes to GitHub.

   **Skip any block carrying a `*Withdrawn ...*` line or a `withdrawn:` mark on its heading.** Those findings were argued down by the author and taken off the PR; they stay in the document so the argument stays on the record. Reposting one would put back the exact comment someone already had removed.

   Keep any GitHub permalinks in the comment body intact (see "Link File References in Comment Bodies" above). They render as clickable links in the posted comment. The same applies to the `summary` field and `unmapped_comments` descriptions.

   Bodies must already carry the seam structure (see "Break at the seam" under Inline Comment Voice in `review.md`); copy their blank lines into the draft payload verbatim.

   Look for this pattern in the review file:
   ```
   #### `<file_path>:<line_number>`
   ```text
   <comment body>
   ```
   ```

2. **Map comment locations to diff positions**: Build a targets array and run through the position mapper:

```bash
~/.agents/skills/review-code/scripts/diff-position-mapper.sh --diff-file "<diff_path>" <<'EOF'
{"targets": [<targets array>]}
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
  "original_diff_path": "<diff_path>",
  "review_file": "<review_file from session>",
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

Don't catalog or preview the inline comments either. The author scrolls down and sees them. Mention something in the summary only if it doesn't have a natural inline target (cross-cutting concerns, missing tests for a behavior that spans files, false-positive callouts on prior reviews).

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
- "One performance suggestion in the hot path, a rename worth doing now, a few clarity nits, and some test coverage gaps." (catalogs the inline comments; the author can see them)

**Code Suggestions:**

When recommending a code change, use GitHub's suggestion syntax in the comment body:

````markdown
```suggestion
replacement code here
```
````

This renders as an "Apply suggestion" button the PR author can click to commit the change.

5. **Create the pending review**:

The heredoc is safe here because the payload is JSON. Comment bodies quote code
from the PR, so a body can contain the delimiter, but a JSON string cannot hold
a literal newline: it arrives as `\nEOF\n` on one line rather than as a bare
`EOF` at column zero. Keep the payload valid JSON and that stays true. Free-form
text would not be safe this way, which is why the architectural context is
written with the Write tool instead.

```bash
~/.agents/skills/review-code/scripts/create-draft-review.sh <<'EOF'
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
- Add additional comments
- Submit with Approve/Request Changes/Comment

To reword or drop a comment later, read
~/.agents/skills/review-code/handlers/amend-pending-review.md.
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
  4. Clean up the session: `~/.agents/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"`
  5. **Stop here.** Do not post the findings any other way: a regular PR comment or a direct `gh pr review` call publishes immediately instead of staying pending (and the PreToolUse hook blocks the direct calls regardless).

### Amending a Draft After It Is Posted

**Nothing in this section runs during a review.** It is here so the correction path sits next to the posting path; skip it unless the user is asking to change a comment on a review that is already on GitHub.

A finding that gets argued down, or one whose wording turns out to be wrong, does not need a new review. Read `~/.agents/skills/review-code/handlers/amend-pending-review.md` and follow it. Never reach for a raw `gh api` call: the PreToolUse hook blocks those endpoints on both REST and GraphQL, and re-running the review to fix one sentence costs every agent again and renumbers every comment.

### Resolve Addressed Threads (--append, PR Mode Only)

When this is an **append** review (`append` is true in the session JSON), resolve the review threads from your previous review whose findings the author has since addressed. This keeps the PR's unresolved-thread list honest: stale threads you already re-checked shouldn't keep nagging the author.

Skip this step entirely if `append` is not true. This step runs whenever `append` is true, independent of `--draft`: a `--draft` posting that was skipped or failed earlier does not skip thread resolution.

**Determine your reviewer identity.** Use `reviewer_username` from the session JSON. If it is empty, fall back to:

```bash
gh api user --jq '.login'
```

Call the result `$reviewer`. If you cannot determine a login, skip this step (without an author scope you cannot safely tell your threads from a teammate's).

**List your unresolved threads.** Scope strictly to threads whose first comment is yours:

```bash
~/.agents/skills/review-code/scripts/resolve-review-threads.sh <pr_number> --author "$reviewer" --json
```

The output `threads` array holds objects with `commentId`, `path`, `line`, `isOutdated`, `author`, and `body` (the full text of your original comment, used for the re-flag comparison below). If the array is empty, there is nothing to resolve; skip the rest of this step.

**Decide which threads to resolve.** Resolve a thread **only when you are confident the finding is addressed**, which requires BOTH signals:

1. **The code at that location changed.** Either the thread's `isOutdated` is true, or the current review diff touches `path` at or near `line`. Requiring this is what stops you from resolving a still-open issue that a flaky re-run merely failed to surface.
2. **Your fresh findings do not re-flag the same issue.** No finding in this review covers the same `path` within ~5 lines of `line` describing the same concern as the thread's `body`. Read the whole `body` (the listing carries up to ~1500 characters), not just its opening: a partial fix often changes the line while leaving the issue the comment described.

A thread that fails either signal stays open. When in doubt, leave it open: resolving is irreversible and visible to everyone on the PR.

Build `$resolve_ids` as the list of `commentId` values that pass both signals.

**Resolve the confident set.** If `$resolve_ids` is non-empty, pass each as a `--comment-id`, keeping the `--author` scope as a safety guard so a stray id can never resolve a teammate's thread:

```bash
~/.agents/skills/review-code/scripts/resolve-review-threads.sh <pr_number> --author "$reviewer" \
  --comment-id <id1> --comment-id <id2> --json
```

**Report.** Tell the user what changed and why, listing each resolved thread with its reason and each thread you deliberately left open:

```
Resolved 2 threads from the previous review:
- src/api.py:42 — code changed and no longer flagged
- src/db.py:88 — thread outdated, fix confirmed

Left open 1 thread:
- src/auth.py:12 — re-flagged in this review
```

If `$resolve_ids` was empty, say so briefly (e.g. "No previous-review threads were confidently addressed; left all open.").
