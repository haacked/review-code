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

If user selects "Cancel": clean up the session, then stop (a worktree may have been provisioned for this session; this releases it instead of leaving it behind).

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

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

If user selects "Cancel": clean up the session, then stop.

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

**If `file_info.file_exists` is true** (a review file exists but neither of the above conditions apply):

First, check the session JSON for `overwrite` and `append` flags:
- If `overwrite` is true: proceed as "Overwrite" (replace the existing review) without prompting.
- If `append` is true: proceed as "Append" (add new findings to the existing review) without prompting.
- Otherwise, use AskUserQuestion to ask what to do with the existing review:
  - Options:
    1. "Overwrite": Replace the existing review
    2. "Append": Add new findings to the existing review
    3. "Cancel": Stop without reviewing

If user selects "Cancel": clean up the session, then stop.

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

### Extract Session Data

From the session file JSON, extract these fields for building agent context:
- `mode`: review mode (pr, branch, commit, range, local)
- `diff`: the code changes to review
- `file_metadata`: metadata about changed files
- `review_context`: language/framework-specific guidelines
- `git`: git repository context
- `languages`: detected languages
- `file_info.file_path`: where to save the review
- `file_ref`: (optional) git ref for reading PR files when on a different branch or via a provisioned worktree
- `commit_messages`: (optional) commit messages for the reviewed changes (subject + body, truncated to 8KB)
- `chunks`: (optional) array of chunk objects when the diff was split
- `chunk_metadata`: (optional) object with `chunked`, `reason`, `chunk_count`
- `debug_session_dir`: (optional) path to debug session directory when debug mode is enabled
- `adversary`: (optional) object `{engine: "copilot"|"codex", available: boolean}`, present only when `--adversary:copilot` or `--adversary:codex` was specified. `available` reflects whether that engine's CLI is actually installed.

Mode-specific fields:
- **PR mode:** `pr`: PR details (number, title, author, body, comments, etc.); `file_ref`: git ref for file access (present when reviewing from a different branch or via a provisioned worktree). When the review runs outside the PR's repo and a local clone is mapped in `repos.conf`, `git.working_dir` points at a detached worktree checked out to the PR. Otherwise (no mapping, provisioning failed, or the PR ref could not be fetched into an in-repo clone), `working_dir` is null and only the diff is available.
- **Branch/commit/range modes:** `branch`, `base_branch`, `commit`, `range`
- **Area-specific reviews:** `area`

### Load Conditional Instructions

Some steps apply only to certain sessions, and their instructions live in separate handler files. Check the session JSON now and Read every file whose condition holds, in one pass, before continuing:

| Condition (session JSON) | Read this file |
|---|---|
| `debug_session_dir` is a non-empty string | `~/.claude/skills/review-code/handlers/review-debug.md` |
| `chunk_metadata.chunked` is `true` | `~/.claude/skills/review-code/handlers/review-chunked.md` |
| `adversary` is present | `~/.claude/skills/review-code/handlers/review-adversary.md` |
| `mode` is `"pr"` | `~/.claude/skills/review-code/handlers/review-pr-output.md` |
| `fix` is `true` | `~/.claude/skills/review-code/handlers/review-fix.md` |

Each file states where in the flow below its steps run. If no condition holds, read nothing and continue.

### Classify Review Scope

Run the scope classifier to determine exploration depth and agent selection based on diff size and file characteristics:

```bash
~/.claude/skills/review-code/scripts/classify-review-scope.sh "$SESSION_FILE"
```

Parse the JSON output and store:
- `$exploration_depth`: "minimal", "standard", or "thorough"
- `$selected_agents`: array of agent area names to invoke (e.g., ["correctness", "security", "testing"])
- `$skipped_agents`: array of agents that will not run
- `$classification_reasoning`: human-readable explanation

**Override rules:**
- If the user specified an `area` (e.g., `/review-code pr 123 security`), ignore the classifier output and use only that area's agent. Set `$selected_agents` to `["$area"]`, `$skipped_agents` to all other agents, `$classification_reasoning` to `"Area override: user requested area '$area'"`, and `$exploration_depth` to "standard" for area-specific reviews.
- If the classifier errors, fall back to all 7 core agents (+ frontend if applicable) and "thorough" exploration.

If agents are being skipped, briefly note this to the user:

```
Scope: $classification_reasoning
Skipping: $skipped_agents (join with ", ")
```

### Debug Mode Setup

If you loaded `review-debug.md` (`debug_session_dir` set), store `$debug_session_dir` now and write its per-stage artifacts as the flow reaches each stage.

### Track Token Usage

Track API token consumption across all agents dispatched during the review. The Agent/Task tool returns usage metadata at the end of each response:

```
<usage>total_tokens: NNN
tool_uses: NNN
duration_ms: NNN</usage>
```

Maintain a `$token_usage` map throughout the review. After each Agent/Task tool invocation completes (context explorer, review agents, chunk analyzers, finding validators), parse the `<usage>` block from its response and record `total_tokens`, `tool_uses`, and `duration_ms` keyed by agent name (e.g., `context_explorer`, `code-reviewer-security`, `chunk-1-analysis`, `validator-1`). If the usage block is absent from a response, skip that entry.

### Prepare File Access Instructions

Build `$file_access_instructions` based on the session data. This block is included in both the context explorer and agent prompts. Substitute the actual `git.working_dir` path into the instructions when `working_dir` is set. Do not emit `$git.working_dir` or similar placeholders verbatim.

`git.local_clone` is set only for cross-repo reviews where a detached worktree was provisioned from a configured clone; when it is set and `working_dir` is set, `working_dir` is that worktree and Read/Grep/Glob read the PR's files directly. In the same-repo cross-branch case, `local_clone` is null and `working_dir` is the user's current checkout (which may be on a different branch), so Read on `working_dir` would read the wrong content for PR files.

**If `working_dir` is set and `file_ref` is set and `local_clone` is set:**
```
**File Access:**
A detached worktree checked out to this PR is available at the path given by `git.working_dir` in the session data. Use Read, Grep, and Glob normally; they operate on that directory. Do not run `git checkout` or `git switch` anywhere, and do not run other write operations in the worktree; the orchestrator owns its lifetime.
```

**If `working_dir` is set and `file_ref` is set and `local_clone` is null:**
```
**File Access:**
You are reviewing from a different branch in the same repo. The user's working tree at `git.working_dir` is on a different branch than the PR, so Read/Grep/Glob there see the wrong file contents for the PR. To read files as they appear in the PR, use `git show "$file_ref:<path>"` via the Bash tool (substitute the actual ref from the session data and always quote the argument to handle paths with spaces or special characters). Do NOT use `git checkout` or `git switch`: this would modify the user's working tree. Read, Grep, and Glob are still useful for finding patterns and conventions in the user's working tree, just not for reading the PR's file contents. `git show` works for any file that exists at the ref, including files newly added in the PR. If `git show` fails (e.g., the file was deleted or renamed, the path is wrong, or the ref was not fetched), fall back to the diff content.
```

**If `working_dir` is set and `file_ref` is NOT set:**
```
**File Access:**
You are on the PR's branch in the user's working directory. Use the Read tool to read files normally. Do not run `git checkout` or `git switch`: it would disturb the user's working tree.
```

**If `working_dir` is null:**
```
**File Access:**
No safe local checkout is available for reading PR files. This can happen because no local clone is configured for the repo in `repos.conf`, because worktree provisioning failed, or because the PR ref could not be fetched into the user's clone. Work primarily from the diff content, but when a finding hinges on control flow, ordering, or behavior the diff hunk doesn't show, fetch the specific file rather than concluding you can't tell (see "Verify before asking or hedging" below).
```

### Gather Architectural Context

Before invoking specialized agents, use the context explorer to understand the codebase.

Invoke the Task tool with subagent_type "code-review-context-explorer" and prompt below. The explorer agent runs on a cheaper model (set in its definition); review agents read the actual code behind any finding before reporting it, so the explorer does not need the top-tier model.

```markdown
Gather architectural context for this code review.

{For PR mode:}
**PR:** #$pr_number - $pr_title
**Description:**
$pr_body

{If pr.linked_issues is not empty:}
**Linked Issues:**
{For each issue in pr.linked_issues:}
- #$issue.number: $issue.title
{End for}

{For branch mode with associated PR:}
**Branch:** $branch vs $base_branch
**Associated PR:** #$pr_number - $pr_title
**Description:**
$pr_body

{For branch mode without PR:}
**Branch:** $branch vs $base_branch

{For commit mode:}
**Commit:** $commit

{For range mode:}
**Range:** $range

{For local mode:}
**Local changes** (unstaged/staged)

{For all modes:}
{If commit_messages is not empty:}
**Commit Messages:**
$commit_messages

**File Metadata:**
$file_metadata

**Diff:**
$diff

$file_access_instructions

{If exploration_depth == "minimal" and "infra-config" is the only agent in $selected_agents:}
Time-box yourself to 30 seconds. This is an infrastructure config review (Helm values, K8s manifests, Terraform, ArgoCD, CI/CD).
Focus on:
- Read the modified files to understand what each configures (service, route, resource)
- Find cross-environment counterparts (dev/staging/prod variants of the same file)
- Note service and resource names referenced in the config
Do NOT search for code callers, function patterns, or application architecture.

{If exploration_depth == "minimal" (non-infra):}
Time-box yourself to 30 seconds. Focus on understanding what changed:
- Read only the modified files to understand their purpose and the change
- Skip caller search, pattern search, git history, and reference implementations

{If exploration_depth == "standard":}
Time-box yourself to 1-2 minutes. Explore:
- Full context of modified files
- Related code and dependencies
- Callers of modified functions (who calls the changed code and might be affected?)
  (grep for function/method names, report top 3-5 callers per significantly modified function)
- Skip pattern search, reference implementations, and git history

{If exploration_depth == "thorough":}
Explore the codebase to understand:
- Full context of modified files
- Related code and dependencies
- Callers of modified functions (who calls the changed code and might be affected?)
  (grep for function/method names, report top 3-5 callers per significantly modified function)
- Existing patterns for similar functionality
- Reusable utilities or conventions
- Reference implementations (if the description indicates a port, migration, or rewrite)
- Git history for high-churn files and surprising code
  (check `git_history.high_churn` flags in file_metadata; run `git log` for flagged files and for any code whose purpose is non-obvious)

Time-box yourself to 2-3 minutes of exploration.
```

Save the explorer's output as `$architectural_context`. Extract usage metadata from the response and record in `$token_usage["context_explorer"]`.

### Invoke Specialized Review Agents

Invoke the agents determined by the scope classification. If an area was specified, invoke only that agent. Otherwise, invoke all agents in `$selected_agents` in parallel (plus the frontend agent if `languages.has_frontend` is true and "frontend" is in `$selected_agents`).

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
| infra-config | code-reviewer-infra-config | Cross-env consistency, route/service correctness, operational safety, config validation |
| *(frontend detected)* | code-reviewer-frontend | React/TS patterns, components, state, a11y |

**Area-scoped diffs for file-type-scoped agents:**

The frontend and infra-config agents review only their own file types, so don't pay to send them the rest of the diff:

- **code-reviewer-frontend**: replace `$diff` with only the hunks for frontend files: `.tsx`/`.jsx`, `.css`/`.scss`, templates, and `.ts`/`.js` files that sit alongside the changed `.tsx`/`.jsx` files or under the repo's UI source root (e.g., `frontend/`, `web/`, `client/`, `src/components/`). A `.ts`/`.js` file matching neither rule is ambiguous; the rule below says to include it.
- **code-reviewer-infra-config**: replace `$diff` with only the hunks for files where `file_metadata` has `is_infra_config: true`.

In both cases, append after the diff:

```
**Other files changed in this PR (not shown above, outside your review scope):**
<comma-separated list of the remaining changed file paths>
```

All other agents receive the full diff. If slicing is ambiguous for a file (e.g., shared types imported by both frontend and backend), include it; only omit hunks that are clearly outside the agent's scope.

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
{If commit_messages is not empty:}
**Commit Messages:**
$commit_messages

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
1. Quote the exact code you're referencing in your analysis to verify the claim; the comment body itself describes the behavior in plain English (see Inline Comment Voice)
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

**Verify before asking or hedging.**

Before writing a `question:` comment, or hedging a `blocking:`/`suggestion:` finding with "I can't tell from the diff" / "not sure if this is a bug", try to answer it yourself from the source. The author has access to the same files; if the answer is one read away, asking instead of looking is just noise.

When the answer is about file content (does X exist, what does Y do, where is Z defined, which of two calls runs first), try these in cheapest-first order and stop as soon as one works:

1. Grep the diff itself. The change context is already in the session data; many questions are answered there with no extra tool calls.
2. If `working_dir` is set, use Read/Grep on the PR's files at `git.working_dir`.
3. If `file_ref` is set, fetch via `git show "$file_ref:<path>"`.
4. If `pr.head_sha` is available, fetch via `gh api repos/<org>/<repo>/contents/<path>?ref=<sha>` and decode the base64 `content` field.

Only ask the author when the answer genuinely depends on context outside the code: their intent, a future plan, an incident the code is responding to, an external system's behavior. "What do you mean?" / "Does X exist?" / "Where is Y handled?" almost always have an answer in the repo, and asking the author for them wastes their time.

If you exhausted the steps above and still cannot verify a specific fact (the file is outside the diff and not fetchable, the symbol is in a system you don't have access to), you may write a `question:` comment (or note the residual uncertainty in a `blocking:`/`suggestion:` finding), but cite what you checked. "I couldn't find `foo()` in the diff or in `bar.py` at this ref. Is it defined elsewhere, or should this call use `baz()` instead?" beats a bare "Where is `foo` defined?"

**Inline Comment Voice:**

Write comments the way a senior engineer talks in a PR review: direct, specific, and conversational. No headers, no formality, no filler.

- No `**Issue**:` / `**Impact**:` / `**Recommendation**:` headers. Start with the prefix, then flow into natural prose.
- Describe behavior, cite the code. When a sentence explains what code does, say it in plain English and carry a `path:line` citation for the claim (in PR mode the linkify step turns these into permalinks). Reserve inline code for the identifier the author must act on, an exact value or error message that matters ("stays at 22", `TypeError`), or a name with no natural English equivalent. If the reader has to mentally execute a quoted expression to follow the sentence, describe what the expression does instead and cite where it lives.
- For `blocking:` and `suggestion:` findings, always include a concrete code fix (see Accuracy Requirements above). For `question:` and `nit:`, offer code when it helps. Use GitHub's `suggestion` syntax for single-line fixes.
- Write about the code, not the author. "This exception propagates as a 500" not "you should catch this exception."
- Match certainty to label. State findings plain when they're clear in the diff; use `question:` when the answer depends on callers, runtime config, or prior conventions. Express uncertainty plainly: "Unless I'm missing something."
- Defer on judgment calls: "your call", "worth considering", "that said."
- Lead with the consequence. Sentence 1 names what breaks or what's at risk; the rest gives enough mechanism to show why. Two failure modes: opening with a verdict ("this is a real upgrade-window risk") or mid-mechanism ("this `it.each` only feeds numeric timestamps, so the guards never run"). Both make the author dig before reaching the point.
- Anchor in what the code does today. "This branch has no coverage" beats "if someone later swaps the guard…."
- One finding per comment. Length: `nit:` ≤ 2 sentences; others ≤ ~4 plus the fix. When the mechanism needs before/after context to be understandable, spend an extra plain-English sentence rather than compressing into a dense code-quoted one; clarity beats compression, and every sentence still has to earn its place. After drafting, cut anything the author already knows, any clause that restates the line above, any adjective doing no work.
- Break at the seam. When a comment runs past two or three sentences, put a blank line between the problem (what breaks and why) and the recommendation (what to do). Two short paragraphs scan faster than one dense block. Never break inside a code block or between the body and its metadata line.

Before posting, run the smell test:

1. Does sentence 1 name the consequence (not a verdict, not a mechanism)?
2. Any phrase that *labels* instead of *names*, or that takes logic-class vocabulary to parse ("conjunct", "vacuously", "holds")? (see the table)
3. Any "it"/"this"/"that" whose nearest preceding noun isn't what you mean?
4. Anything the author already knows from having written the code? Cut it.
5. Would you say this sentence to a colleague out loud?
6. More than two or three sentences with no blank line? Split the problem from the fix.
7. Does any sentence require parsing a quoted code expression to follow it? Describe the behavior in plain English and cite the location.

Cut on sight (the label → say the thing instead):

| Don't write | Write |
|---|---|
| "the headline behavior", "the core path here", "the key thing" | name it: "counting events by the team's local day is the whole point here" |
| "weak positive assertion", "tautology", "invariant violation" | the scenario: "the count stays 22 and the test still passes" |
| formal logic vocabulary: "this conjunct is always satisfied", "vacuously true", "the predicate holds" | what the code does: "the `!== true` check always passes", "the list is empty, so the loop never runs" |
| coined hyphen-jargon: "migrated-forward home", "missing-timestamp side" | plain: "the case where one side has no timestamp" |
| coined noun-phrase labels: "the withholding boundary", "the staleness window" | the sentence the label compresses: "the endpoint doesn't return a person's other distinct IDs to `feature_flag:read`-only tokens" (the author can't expand a name they've never seen) |
| metaphor-jargon: "load-bearing", "code smell", "foot-gun" | the concrete behavior: "has to stay inside the function or it's a circular import" |
| "fails to handle", "remains at its prior value", "is invoked a single time" | "doesn't catch", "stays at 22", "runs once" |
| "this is critical", "real risk", "meaningful state change" | say what concretely breaks |
| "It's not just X, it's Y", "Great work", "Just a thought, but…", "Hope that helps!" | cut it (the prefix already signals priority) |
| reviewer-internal vocabulary: "sibling", "the closest sibling to mirror", "anchor", "corroborated" | name the thing and where it is: "mirror `test_saving_flag_strips_legacy_holdout_groups`, just above", "the two tests above this one" |
| quoted expressions as sentence subjects: "since `"groups" not in filters` never fires" | describe the behavior and cite the line: "the shortcut that skips full validation never applies here, because the write always includes `groups` (feature_flag.py:1241)" |
| em dash (—) | comma, colon, semicolon, parentheses, or two sentences |

Two worked examples. First, lead with the consequence instead of a verdict:

Good:
```
`blocking`: On self-hosted, this rename has a stale-cache problem after deploy. `License.update_available_product_features()` only re-syncs on org create, license save, or the hourly Celery beat at `:30`. Existing Enterprise orgs keep the old key and don't pick up the new one for up to an hour, and every gate that switched silently turns off in that window.
```

Bad:
```
`blocking`: This is the spot that produces a real upgrade-window risk on self-hosted. `License.update_available_product_features()` only re-syncs on org create, license save, or the hourly Celery beat at `:30`. On a code-only deploy, an existing Enterprise org's `available_product_features` still holds the old key until the next tick, ~up to 60 minutes.
```
(The bad version opens with a verdict; the author has to clear the framing before reaching what the code is doing.)

Second, name the behavior instead of coining a label, and anchor in the present:

Good:
```
`suggestion`: Nothing tests what happens when one side has no `$feature_flag_evaluated_at`. That's the documented case where the group entry should win (a migration leftover, or an older SDK that wrote before this field existed), but all three `it.each` cases pass a numeric timestamp on both sides, so the `isNumber()` guards in `_groupEntryIsStale` always pass and that branch never runs.

Add a case where one side omits the timestamp and assert the group still wins.
```

Bad:
```
`suggestion`: This it.each only feeds numeric timestamps, so the isNumber(groupLoadedAt) && isNumber(mainLoadedAt) guards in _groupEntryIsStale never run against a missing-timestamp side. Those guards are what keep the group entry winning as the migrated-forward home when one side has no $feature_flag_evaluated_at (an older-SDK or pre-stamp write). If someone later drops them for a plain mainTs > groupTs, a group entry with no timestamp would start losing to an undefined main timestamp and the cached flags would silently flip, with no test to catch it. Add a case where one side omits $feature_flag_evaluated_at and assert the group still wins.
```
(The bad version opens mid-mechanism, coins jargon ("migrated-forward home", "missing-timestamp side"), and builds the case around a future refactor that hasn't happened. The good version leads with the gap, gives just enough mechanism to see why that case never runs, and puts a blank line before the ask so the recommendation stands on its own.)

Third, describe behavior instead of quoting expressions:

Good:
```
`blocking`: Deleting an Early Access Feature can now fail. Before this change, cleanup wrote the flag's filters straight to the database with no validation; it now goes through `update_flag`, which validates the stored filters (products/early_access_features/backend/api.py:214). A legacy flag with a property missing `key` fails that validation with a raw `TypeError` from the pre-delete hook (products/early_access_features/backend/apps.py:45), which has no error handling.

Wrap the cleanup write in try/except and fall back to the raw save, so a legacy flag that fails validation still deletes cleanly.
```

Bad:
```
`blocking`: This turns "destroy always succeeds" into "destroy can fail." Before this PR, `related_feature_flag.filters = ...; related_feature_flag.save()` never validated the flag, so cleanup always went through. Now `update_flag` runs the flag through `FeatureFlagSerializer`'s full `validate_filters`, and since `set_feature_enrollment` spreads the entire stored filters, the `"groups" not in filters` partial-update escape hatch (feature_flag.py:1241) never fires, so a group-aggregated flag hits the hard rule at feature_flag.py:1367 and `Property(**prop_dict)` raises a raw `TypeError` at feature_flag.py:1380.
```
(The bad version makes the reader execute quoted expressions to follow the argument, and packs two failure modes into one comment. The good version covers one failure mode, says what the code does in plain English, cites each claim with a repo-root `path:line`, and quotes only the tokens the author will act on. The second failure mode gets its own comment.)

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

After all review agents complete, extract usage metadata from each agent's response and record in `$token_usage` keyed by agent type (e.g., `$token_usage["code-reviewer-security"]`).

**Chunked review dispatch:** If you loaded `review-chunked.md` (large diff split into chunks), dispatch per its instructions instead — per-chunk analysis, then chunk x agent combinations — and merge all findings into a single pool for the synthesis below.

**Pre-synthesis scope filter**

After all agent results are collected (including all chunks in chunked mode), apply this filter before synthesis:

1. **Build the in-scope file list.** Let `IN_SCOPE_PATHS` be the set of file paths from `file_metadata.modified_files[].path`. These are the only files the PR is considered to touch for this filter.

2. **For each finding, check whether it is located at a specific file.** A finding has a specific file location if it names a path as the target of the issue (e.g., `src/api/views.py:42`, a section header like `#### src/api/views.py`, or an explicit `path:` field). Passing mentions of a filename inside prose (e.g., "This pattern is also used in `utils/helpers.py`") do not count.

3. **Apply the rule:**
   - Finding is located at a file **in** `IN_SCOPE_PATHS`: keep it.
   - Finding is located at a file **not in** `IN_SCOPE_PATHS`: drop it silently.
   - Finding has **no specific file location** (e.g., a general architectural observation): keep it.

This filter reduces noise before the expensive extended-thinking synthesis step. Line-level precision is handled later by the "Validate Findings Against the Diff" step.

Synthesize the remaining findings using extended thinking into a coherent, deduplicated review document. Apply confidence-based filtering and cross-agent corroboration before producing the final output.

**Cross-agent corroboration:** Two findings are corroborated if they reference the same file within 10 lines, or the same logical concern in the same function. Cross-model corroboration (an adversary meta-review `CONFIRMED` verdict, only when an adversary pass ran) also counts as corroboration even if only one Claude agent flagged the issue.

**Filtering rules:**
- **Corroborated (2+ agents or chunks):** Keep even if individual confidence is below 40%.
- **Solo finding, confidence >= 40%:** Include as-is.
- **Solo finding, confidence < 40%:** Drop silently.
- **Questions and nits:** Exempt from filtering. Include regardless of confidence.
- When consolidating corroborated findings, merge into a single entry using the highest confidence value. Corroboration is synthesis-time metadata used for prioritization; never embed it in the comment body (see "Comment Body Hygiene" below).

**Comment Body Hygiene:**

The `description` and `proposed_fix` text becomes the literal body of the PR review comment. Keep it free of process and provenance metadata. Do not append, prepend, or embed:

- Agent or model attribution: "*(corroborated by Copilot)*", "*(Copilot confirmed)*", "*(Copilot disagreed: …)*", "*(Copilot note: …)*", "*(flagged by Copilot during meta-review)*", the same phrasing with "Codex" in place of "Copilot", "*(corroborated by correctness and architecture)*", "*(found by code-reviewer-security)*", or any similar tag naming a reviewer agent, model, or pipeline stage.
- Validation provenance: "*Downgraded from blocking: [validator reasoning]*" or any other note that exists to record the synthesis pipeline's verdict.
- Confidence percentages, agent IDs, or any other internal scoring.

Exception: if a model name like "Copilot" or "Codex" appears in a parenthetical that is substantive content about the code under review (e.g., "*(the Copilot SDK rejects this header)*"), keep it. The rule targets pipeline bookkeeping, not technical claims that happen to mention a product.

Corroboration, dismissal reasoning, and confidence are signals the synthesis stage uses for filtering and ordering. Track them in your working state (the in-memory finding objects during consolidation), not in the `description` or `proposed_fix` fields. If you need to record provenance for debugging, use `$debug_session_dir` artifacts (e.g., `11b-adversary-meta-review/response.json`), never the comment body.

**Priority ordering in the final review:**
1. Corroborated blocking findings
2. Solo blocking findings (>= 70% confidence)
3. Corroborated suggestions
4. Solo suggestions (>= 40% confidence)
5. Questions and nits

### Validate Findings Against the Diff

Before including any finding in the final review, verify it references code actually in the diff (across all chunks if chunked). This catches wrong line numbers, findings about unrelated files, and stale references.

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

**Step 3: Verify factual claims.** For any remaining finding that claims a bug or incorrect behavior:

- **If `blocking:`**: Invoke the Task tool with `subagent_type` "finding-validator" for each blocking finding, using this prompt:

  ````
  Validate this blocking finding from a code review.

  **Finding:**
  - **Source agent:** $agent_name
  - **Location:** $file:$line
  - **Confidence:** $confidence%
  - **Description:** $finding_description
  - **Proposed fix:**
  $proposed_fix

  **Code context from the diff:**
  ```
  $relevant_diff_snippet
  ```

  $file_access_instructions

  Read the file at `$file` (around line `$line`) and determine whether this finding is real or a false positive. Try to disprove it. Respond with CONFIRMED or DISMISSED and your reasoning.
  ````

  Dispatch all blocking finding validations **in parallel**. Extract usage metadata from each validator's response and record in `$token_usage` as `validator-{N}` (numbered sequentially). For each result:
  - **DISMISSED**: downgrade to `suggestion:`. If the validator's reasoning sharpens the technical content (a missing condition, a corrected line number), fold that into the body as if it were original analysis. Do not embed validator attribution like "*Downgraded from blocking: …*"; the body must stay free of pipeline metadata (see "Comment Body Hygiene").
  - **CONFIRMED**: keep as `blocking:`.
  - **Unreachable or errors**: keep the finding as-is.

- **Otherwise** (non-blocking findings): Use the Read tool to verify the claim is accurate before including it.

### Adversary Meta-Review

If you loaded `review-adversary.md` (`--adversary:*` flag), run its meta-review pass here, between finding validation and the Voice Pass. Otherwise continue to the Voice Pass.

### Voice Pass (Final Rewrite)

Before composing the review document, run a single voice-pass agent over the surviving findings to rewrite their `description` and `proposed_fix` text in a clean, conversational voice. The voice agent never changes severity, citations, line numbers, identifiers, numbers, or code blocks; it changes phrasing and paragraph structure, nothing else.

**Skip conditions:** If `$selected_agents` is empty (no findings will be produced) or the surviving finding pool is empty, skip this step entirely.

**Build the input.** Collect all findings that survived synthesis, validation, and the adversary meta-review (the same pool the document composer will use). For each, include an integer `id` (sequential, starting at 1), `severity` (`blocking`/`suggestion`/`question`/`nit`), `location` (file:line or file path), `description` (the comment body, including any embedded code blocks), and `proposed_fix` (string or null). Build a JSON array.

**Dispatch the rewrite.** Invoke the Task tool with subagent_type `code-reviewer-voice` and a prompt that:

1. Tells the agent to rewrite the `description` and `proposed_fix` fields in conversational voice while preserving every citation, file path, line number, identifier, number, and code block exactly.
2. Tells the agent it is also responsible for paragraph structure: any body with three or more sentences must have a blank line separating the problem (what breaks and why) from the recommendation (what to do); enumerations that restate what an attached code block already shows get cut; a `nit:` body is at most two sentences. This structural responsibility does not license changing citations, code blocks, severity, or technical claims.
3. Embeds the JSON array of findings inside a **four-backtick** fence tagged `json` (because finding bodies typically contain triple-backtick code blocks; a three-backtick wrapper would close prematurely).
4. Reminds the agent to wrap its response in a four-backtick `json` fence in the same order as the input, with `id`, `description`, `proposed_fix`, and `unchanged` on each object.

Save the agent's response. Extract usage metadata and record in `$token_usage["code-reviewer-voice"]`.

**Parse the output.** Extract the JSON array from the response. For each rewritten finding, match it to the input by `id`.

- If `unchanged: true` on a rewritten finding, skip validation and keep the original `description` and `proposed_fix` for that finding (the agent is signaling no improvement was needed).
- If an input `id` has no matching rewrite, keep the original.
- If a rewritten entry has an `id` that doesn't appear in the input, ignore that entry and count it as a parse anomaly toward the validation-failure budget below.
- If the returned array length differs from the input array length by more than 1, treat the entire response as malformed and apply the agent-error fallback (continue with original findings).

**Validate preservation.** For each rewritten finding where `unchanged` is `false`, before accepting the change:

1. Confirm the severity prefix matches: extract the prefix token from each (`` `blocking`: ``, `` `suggestion`: ``, `**blocking**:`, bare `blocking:`, etc.) and check string equality. If the prefix differs in any way, fail the check.
2. Confirm the rewritten body contains every backtick-quoted token from the original whose text matches a file-path pattern (e.g., `auth.py:45`, `src/foo.ts`, `path/to/file.py`) or a numeric line reference (e.g., `:67`, `line 67`). Identifiers and exception names that happen to be backtick-quoted (`OverflowError`, `dateutil.parser.parse()`) are not subject to this check. If the original contains no path-shaped or line-number tokens, skip this check.
3. Confirm the rewritten body length is not greater than the original by more than 5% (allowing slack for punctuation tweaks and inserted paragraph breaks; a blank line adds two newline characters and never fails this check on its own).

If any check fails, discard the rewrite and keep the original finding. Track the failure count in `$token_usage["code-reviewer-voice"].validation_failures`.

**Failure modes (all fail open, never blocking the review):**

- **Agent times out or errors:** Continue with original findings.
- **JSON parse fails or array length differs by more than 1:** Continue with original findings.
- **More than 50% of findings fail validation:** Discard all rewrites. The voice agent is misbehaving; better to ship verbose comments than wrong ones.

The Voice Pass step runs in all review modes (quick and comprehensive) when findings exist. There is no mode-based guard.

In debug mode, save the stage `11c-voice-rewrite` artifacts (see `review-debug.md`).

### Link File References in Comment Bodies

If you loaded `review-pr-output.md` (PR mode), run its "Link File References in Comment Bodies" step here, right after the Voice Pass. Other modes leave references as plain `path:line` text.

### Apply Fixes (--fix flag)

If you loaded `review-fix.md` (session has `fix: true`), apply fixes per its instructions now, before composing the review document.

### Compose the Review Document

**Title by mode:**

| Mode | Title format |
|------|-------------|
| PR | `Pull Request Review: #$pr_number - $pr_title` |
| Commit | `Commit Review: $commit` |
| Branch | `Branch Review: $branch vs $base_branch` |
| Range | `Range Review: $range` |
| Local | `Code Review: (org/repo) - (branch) (uncommitted)` |

**For comprehensive reviews**, include a section for each agent that ran (from `$selected_agents`):
- Security Review (if "security" in `$selected_agents`)
- Performance Review (if "performance" in `$selected_agents`)
- Correctness Review (if "correctness" in `$selected_agents`)
- Maintainability Review (if "maintainability" in `$selected_agents`)
- Testing Review (if "testing" in `$selected_agents`)
- Compatibility Review (if "compatibility" in `$selected_agents`)
- Architecture Review (if "architecture" in `$selected_agents`)
- Infra-Config Review (if "infra-config" in `$selected_agents`)
- Frontend Review (if "frontend" in `$selected_agents`)

**For area-specific reviews**, include only that area's findings.

If the session has `fix: true`, place the `## Fix Summary` section (built by the fix pass in `review-fix.md`) directly after the metadata header (and after the chunked "Review Scope" note, when present) and before the per-agent sections.

Include the metadata header at the top of the file:

```html
<!-- review-metadata
reviewed_at: <current ISO 8601 timestamp>
mode: <mode>
pr_number: <pr_number if applicable>
org: <org>
repo: <repo>
review_commit: <pr.head_sha if PR mode, omit otherwise>
scope:
  exploration_depth: <exploration_depth>
  agents_run: <$selected_agents as comma-separated list>
  agents_skipped: <$skipped_agents as comma-separated list, or "none">
  reasoning: <$classification_reasoning>
token_usage:
  <agent_name>: <total_tokens>
  ...
  total: <sum of all total_tokens>
diff_tokens: <diff_tokens from session data>
-->
```

The `token_usage` block records per-step token consumption (agents, context explorer, validators, and other steps) and the aggregate total. Always include the `total` field as the sum of all steps in `$token_usage`.

This metadata is used by the learning system to determine when the review was created. The `review_commit` field records the PR's HEAD SHA at review time, enabling drift detection when creating draft reviews later. The `diff_tokens` field is an estimated token count of the diff (~4 chars per token).

**Narrative voice.** The Inline Comment Voice rules earlier in this handler govern the comment bodies; the narrative you compose here (Overview, findings prose, per-agent sections, the metadata `reasoning` field) needs the same register. Write it the way you'd write a Slack summary to a colleague who is about to review the code: plain verbs, short sentences, no ceremony. Three tells to avoid outright:

- Em dashes (`—`, U+2014). Restructure the sentence instead: a period and two sentences, a colon, parentheses, or a comma where it genuinely fits. Hyphens (`-`) and en dashes (`–`) are fine.
- Bold inside a prose sentence. Bold is for line-start labels, headings, and table cells. If a clause feels like it needs bold for emphasis, the sentence is buried; lead with it instead.
- Inflation and AI vocabulary: "critical", "robust", "comprehensive", "leverage", "utilize", "ensure", "It's not just X, it's Y". Say what the code does.

An Overview paragraph in the right register reads like:

> Adds a soft-hide for stale suggestion names. The new boolean ships in an additive migration, the GET returns hidden names separately, and hide/restore is admin-gated. The hidden row and any flags using it are preserved, so hiding is reversible.

Save the complete review to `$review_file` and inform the user with a clickable file link:

```
Review complete!

{If PR mode:}
Pull Request: $pr_url

Review saved to: $review_file

{If session has fix: true and fixes were applied:}
Fixes applied: $H high-confidence, $J judgment calls, $S skipped. See "Fix Summary" in the review for details.

{If session has fix: true and preconditions failed:}
Fixes were requested but not applied: $reason. See "Fix Summary" in the review.

You can open it directly: file://$review_file

Token usage: ~$total_tokens tokens across $step_count steps ($exploration_depth exploration)
```

Where `$total_tokens` is the sum of all `total_tokens` from `$token_usage` and `$step_count` is the number of entries (includes agents, context explorer, validators, and other steps).

In debug mode, save the stage `12-token-usage` artifacts (see `review-debug.md`).

**Do NOT post the full review to GitHub.** The detailed review is saved to the markdown file only. If `--draft` mode is enabled, a separate draft review with inline comments will be created in the next step. That draft contains only brief inline comments, not the full review summary.

### Log Token Usage

After saving the review, append a line to a central token usage log. This tracks token counts across reviews over time.

Derive the log path from the review file's directory: take the parent of the `org/repo/` directory (i.e., the review root) and append `token-usage.jsonl`. For example, if `$review_file` is `~/dev/ai/reviews/posthog/posthog/pr-123.md`, the log path is `~/dev/ai/reviews/token-usage.jsonl`.

In practice, this is the great-grandparent directory of `$review_file` (three directories up):

```bash
token_usage_log="$(dirname "$(dirname "$(dirname "$review_file")")")/token-usage.jsonl"
```

Each line is a JSON object:

```json
{"reviewed_at": "<ISO 8601 timestamp>", "org": "<org>", "repo": "<repo>", "mode": "<mode>", "identifier": "<pr_number or branch name>", "diff_tokens": <diff_tokens>, "files_changed": <number>, "lines_added": <number>, "lines_removed": <number>, "exploration_depth": "<exploration_depth>", "agents_run": <number of agents run>, "agents_skipped": <number of agents skipped>, "total_tokens": <sum of total_tokens across $token_usage>, "total_tool_uses": <sum of tool_uses across $token_usage>, "agents": {"<agent key>": <that agent's total_tokens>, ...}}
```

Extract these values from the session data:
- `reviewed_at`: the current ISO 8601 timestamp (same as the review metadata)
- `org`, `repo`: from `summary.repository` (split on `/`)
- `mode`: from `summary.mode`
- `identifier`: PR number if PR mode, branch name if branch mode, commit hash for commit mode, etc.
- `diff_tokens`: from the top-level `diff_tokens` field
- `files_changed`, `lines_added`, `lines_removed`: from `summary.stats`

Compute the token fields from the `$token_usage` map (see "Track Token Usage"):
- `total_tokens`: sum of `total_tokens` over all entries
- `total_tool_uses`: sum of `tool_uses` over all entries
- `agents`: an object with one key per `$token_usage` entry (e.g., `context_explorer`, `code-reviewer-security`, `validator-1`) mapping to that entry's `total_tokens`

These cover subagent consumption only; the orchestrating conversation's own tokens are not measurable from here. If `$token_usage` is empty (e.g., every usage block was absent), log `total_tokens: 0`, `total_tool_uses: 0`, and `agents: {}` rather than omitting the fields. This log is the baseline for measuring cost optimizations, so never skip the token fields.

Use `Bash` with `jq` to append the JSON line (ensures correct escaping and consistent format):

```bash
jq -nc \
  --arg reviewed_at "<timestamp>" \
  --arg org "<org>" \
  --arg repo "<repo>" \
  --arg mode "<mode>" \
  --arg identifier "<identifier>" \
  --argjson diff_tokens <diff_tokens> \
  --argjson files_changed <files_changed> \
  --argjson lines_added <lines_added> \
  --argjson lines_removed <lines_removed> \
  --arg exploration_depth "<exploration_depth>" \
  --argjson agents_run <number of agents run> \
  --argjson agents_skipped <number of agents skipped> \
  --argjson total_tokens <total_tokens> \
  --argjson total_tool_uses <total_tool_uses> \
  --argjson agents '<per-agent JSON object, e.g. {"context_explorer": 42000, "code-reviewer-security": 88000}>' \
  '$ARGS.named' >> "$token_usage_log"
```

### PR Outputs: Suggested Comments, Draft Review, Thread Resolution

If you loaded `review-pr-output.md` (PR mode), run its remaining steps now, in order: "Generate Suggested Comments", "Create Draft Review" (--draft), and "Resolve Addressed Threads" (--append).

### Cleanup Session

After the review is complete, clean up the session (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

This removes the temporary session files and frees up disk space.
