# Handler: Inline Fallback Briefing

Used only when an agent replies `BRIEFING_UNAVAILABLE`, meaning it could not read
the briefing files. Re-dispatch that one agent with the payload inlined below,
substituting each `$variable` from the session file. This is the pre-briefing
dispatch path, kept intact as the fallback; on the happy path it never runs.

Read the session file directly for this. It is the one moment the payload has to
pass through the conversation, which is exactly why this path is the exception.

Two substitutions differ from what the session used to hold:

- `$diff` — the session stores `diff_path`, not the diff itself. Read that file
  (or the agent's scoped `diff-<area>.patch`) and inline its contents here.
- `$architectural_context` — read `<artifacts_dir>/architectural-context.md`.

Everything else (`$pr_body`, `$pr_comments`, `$commit_messages`,
`$review_context`) is still in the session file under those names.

---

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

Analyze like a senior engineer; write the comment for a teammate who has not read the diff and shouldn't have to decode anything: direct, specific, conversational. A dedicated voice agent rewrites every surviving comment body before publication, so spend your effort on the technical content in a plain register. The points below are the ones the voice agent cannot fix afterward; get them right when drafting.

- Lead with the consequence, and name it. Sentence 1 says what breaks or what's at risk; the rest gives just enough mechanism to show why. Don't open with a verdict ("this is a real upgrade-window risk") or mid-mechanism. The voice agent can reorder phrasing but never invents a consequence you didn't state.
- Describe behavior in plain English and cite `path:line` for each claim (in PR mode the linkify step turns citations into permalinks). Reserve inline code for the identifier the author must act on or an exact value that matters ("stays at 22", `TypeError`). If the reader has to mentally execute a quoted expression to follow a sentence, describe what the expression does and cite where it lives; the voice agent isn't allowed to paraphrase quoted code, so this is yours to get right.
- Anchor in what the code does today ("this branch has no coverage"), not in a hypothetical future ("if someone later swaps the guard…").
- For `blocking:` and `suggestion:` findings, always include a concrete code fix (see Accuracy Requirements above); use GitHub's `suggestion` syntax for single-line fixes. For `question:` and `nit:`, offer code when it helps.
- Write about the code, not the author, and match certainty to the label: state findings plainly when they're clear in the diff, use `question:` when the answer depends on callers or config, and defer on judgment calls ("your call", "worth considering").
- One finding per comment. One idea per sentence: if a sentence carries two claims, split it, and state a claim before the evidence for it. Write as many plain sentences as the finding needs; past about 8, it's probably two findings. `nit:` is at most 2 sentences. Past two or three sentences, put a blank line between the problem and the recommendation.
- Say the thing, not a label for the thing: no `**Issue**:`/`**Impact**:` headers, no coined jargon ("the staleness window"), no formal-logic vocabulary ("vacuously true"), no filler. Name the concrete behavior instead.

One worked example: lead with the consequence instead of a verdict.

Good:
```
`blocking`: On self-hosted, this rename has a stale-cache problem after deploy. `License.update_available_product_features()` only re-syncs on org create, license save, or the hourly Celery beat at `:30`. Existing Enterprise orgs keep the old key and don't pick up the new one for up to an hour, and every gate that switched silently turns off in that window.
```

Bad:
```
`blocking`: This is the spot that produces a real upgrade-window risk on self-hosted. `License.update_available_product_features()` only re-syncs on org create, license save, or the hourly Celery beat at `:30`. On a code-only deploy, an existing Enterprise org's `available_product_features` still holds the old key until the next tick, ~up to 60 minutes.
```
(The bad version opens with a verdict; the author has to clear the framing before reaching what the code is doing.)

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

