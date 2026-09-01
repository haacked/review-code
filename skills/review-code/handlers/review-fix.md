## Apply Fixes

Loaded when the session JSON has `fix: true`. This pass runs after semantic composition, the Voice Pass, the final Comprehension Gate, and any file-reference links. It runs immediately before "Compose the Review Document" and applies fixes only for publishable findings.

The goal: act like a principal engineer doing a careful local cleanup pass. Fix what's clearly right; explain what you skipped or where you had to make a judgment call. The fix step never posts to GitHub: it edits the working tree only.

**Preconditions:**

1. `$finding_publication.findings` contains at least one entry. If not, skip the fix step and note "No findings to fix" in the Fix Summary section of the review document.
2. A writable working tree contains the reviewed code. Decide using this table:

   | `mode`                               | `file_ref` set? | `git.local_clone` set? | Apply fixes? | Target / reason it's skipped |
   |--------------------------------------|-----------------|------------------------|--------------|------------------------------|
   | `local`, `branch`, `commit`, `range` | n/a             | n/a                    | yes          | `git.working_dir`            |
   | `area`                               | n/a             | n/a                    | yes          | `git.working_dir`            |
   | `pr`                                 | no              | n/a                    | yes          | `git.working_dir`            |
   | `pr`                                 | yes             | yes                    | no           | working tree is a disposable provisioned worktree; edits would be reaped at session end |
   | `pr`                                 | yes             | no                     | no           | user's working tree is on a different branch; edits would silently corrupt unrelated branch state |

3. The working tree directory exists and is writable.
4. For branch-family reviews (`mode` is `branch`, including no-arg current-branch reviews): the session must NOT have `base_lookup_degraded`. That flag means the open PR's base could not be used (gh offline, unauthenticated, or timed out; base ref not fetched locally; or unrelated history) and the review consequently fell back to the default branch, so on a stacked branch the diff may include a parent PR's commits and applying fixes could edit code this branch doesn't own. Skip with reason "base detection was degraded (the open PR's base could not be used); not auto-editing against the default branch".

If any precondition fails, skip applying fixes but still produce the Fix Summary section with a one-line reason.

**Classification (per finding):**

For each finding in `$finding_publication.findings`, classify it into one of three buckets. The executable publication boundary has already required `publishable: true`, a non-empty body, and valid routing. Each finding has `severity` (blocking/suggestion/nit/question), `file`, `line`, `description`, `proposed_fix`, and `confidence`.

- **`fix_high_confidence`**: apply without commentary in the summary. All of:
  - One of: `severity` is `blocking` or `suggestion` and `confidence >= 80%`; OR `severity` is `nit` and `proposed_fix` is a single-line or single-identifier change.
  - `proposed_fix` is concrete (a diff, replacement code, or precise textual change), self-contained in one file, and unambiguous.
  - The change does not alter a public API, exported type, function signature, or stable identifier that other callers depend on.
  - The change does not require touching files outside the diff's modified files.

- **`fix_with_judgment`**: apply, then record the choice in the summary. Any of:
  - `confidence` is 60–79%.
  - `proposed_fix` exists but needs adaptation (style, naming, placement) before it fits the surrounding code.
  - There are 2+ reasonable approaches and you chose one. Pick the one a principal engineer would defend: clearest read, fewest moving parts, lowest blast radius. Avoid clever or speculative refactors.
  - The fix touches a small amount of related code outside the immediate line (e.g., adding a helper, removing a now-unused import) where doing so leaves the codebase cleaner than the minimal patch.

- **`skip`**: do not apply. Any of:
  - `severity` is `question` (the author needs to decide) or the finding is `nit` without a trivial in-place fix.
  - `confidence < 60%`.
  - No concrete `proposed_fix` is available.
  - The fix would change a public API, exported symbol, or behavior contract.
  - The fix requires domain knowledge or product intent you don't have from the diff and architectural context.
  - The fix would touch files outside the modified set, or would create new files, in a way that goes beyond the finding's stated scope.
  - Applying the fix would create or worsen a conflict with another finding's fix.

When two findings conflict (different fixes proposed for the same lines), pick the one with higher confidence; if tied, prefer `blocking` over `suggestion`. Mark the dropped finding as `skip` with reason "conflicts with higher-priority fix at <file:line>".

**Applying fixes:**

Maintain a `$fix_outcomes` map keyed by finding `id` (the finding contract assigns sequential integer ids) with shape `{ status, file, line, severity, description, reason?, choice? }` where:
- `status` is the bucket name: `fix_high_confidence`, `fix_with_judgment`, or `skip`.
- `reason` is required when `status` is `skip`.
- `choice` is required when `status` is `fix_with_judgment` and explains the option taken and the alternatives considered.

For each finding classified `fix_high_confidence` or `fix_with_judgment`:

1. Read the file named by the finding's `file` to capture the current text.
2. Locate a unique textual anchor for the change using identifiers in the finding's `description` and `proposed_fix`; do not trust the diff's literal line numbers (the working tree may have drifted). If no unique anchor exists, reclassify the finding as `skip` with reason "could not locate fix target after working-tree drift".
3. Apply the change with the Edit tool, using the anchor as `old_string`. Make the smallest edit that fully addresses the finding; do not bundle unrelated cleanups into the same edit. Edit's exact-match contract verifies the change atomically; if it errors, drop the finding to `skip` with the error as the reason.
4. Record the outcome in `$fix_outcomes`.

Group findings by file. Within one file, apply edits sequentially (the Edit tool's exact-match contract makes parallel same-file edits race) and re-read the file before each subsequent edit so anchors reflect prior fixes. Across files, you may dispatch edits in parallel.

After all fixes are applied, do not run formatters, linters, or test suites automatically. The user will review the changes themselves.

**Fix Summary section:**

Build a `## Fix Summary` section. The "Compose the Review Document" step places it immediately after the metadata header (and after the Review Scope note when one is present) and before the per-agent sections.

The summary's opening line is one of two forms:

- When fixes ran: `_Applied via `--fix`. <N> findings reviewed: <H> auto-fixed, <J> fixed with judgment calls below, <S> skipped._` When the session's `base_source` is not `"default"`, name the base so the scope is visible: `_Applied via `--fix` (reviewed against `<base_branch>`). <N> findings reviewed: …_`
- When preconditions failed: `_`--fix` was requested but no fixes were applied: <one-line reason>._`

After the opening line, render the two subsections below. Omit each subsection entirely when its list would be empty.

```markdown
## Fix Summary

<opening line, per the rules above>

### Judgment Calls

- **`<file>:<line>`** (`<severity>`): <one-sentence description of what changed>.
  <One or two sentences naming the chosen approach and the alternatives considered, in plain English.>

### Skipped

- **`<file>:<line>`** (`<severity>`): <one-sentence description>.
  Skipped: <reason in plain English>.
```

List judgment-call and skipped items in priority order. High-confidence fixes are not listed; the diff in the working tree is their record. Counts in the opening line reflect the actual outcomes regardless of which subsections are rendered.

The user-facing summary message picks up the fix counts in the "Compose the Review Document" step. No action needed here.

In debug mode, save the stage `11d-fix-pass` artifacts (see `review-debug.md`).
