# Handler: Compose the Review Document

Loaded when the review is ready to be written out. Kept out of `review.md` so
its text is not carried through every earlier turn of the run.

## Compose the Review Document

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
base_branch: <base_branch if branch mode, omit otherwise>
base_source: <base_source if branch mode, omit otherwise>
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

This metadata is used by the learning system to determine when the review was created. The `review_commit` field records the PR's HEAD SHA at review time, enabling drift detection when creating draft reviews later and giving the next re-review the point to compute its delta from. On `--append`, update the existing header in place; a second header would leave the stale SHA first in the file, where `review-delta.sh` reads it. On the `delta` path the merge script writes the header, so skip it (see below). The `diff_tokens` field is an estimated token count of the diff (~4 chars per token).

If `mode` is `branch` and `base_source` is not `"default"`, add a scope note directly under the metadata header (before the Fix Summary and any chunked "Review Scope" note) so the reader can tell at a glance what the diff was compared against:

> **Review Scope:** Reviewed against base `$base_branch` (<phrase matching `base_source`: "the open PR's base branch" / "the recorded stack parent" / "the `--parent` override">), not the repository default branch.

**Narrative voice.** The Inline Comment Voice rules govern the comment bodies; the narrative you compose here (Overview, findings prose, per-agent sections, the metadata `reasoning` field) needs the same register. The voice agent rewrites finding bodies only and never sees this prose, so it is yours to get right. Write it the way you'd write a Slack summary to a colleague who has not read the diff and shouldn't have to decode anything: plain verbs, short sentences, one idea per sentence, no ceremony. Four tells to avoid outright: em dashes (restructure with a comma, colon, parentheses, or two sentences), bold inside a prose sentence (lead with the point instead), inflation vocabulary ("critical", "robust", "comprehensive", "leverage", "ensure", "It's not just X, it's Y"), and naming a category where the behavior belongs, whether that's a coined label ("the staleness window"), logic vocabulary ("vacuously true"), test-theory jargon ("weak positive assertion"), or pipeline vocabulary the author never sees ("corroborated", "sibling").

An Overview paragraph in the right register reads like:

> Adds a soft-hide for stale suggestion names. The new boolean ships in an additive migration, the GET returns hidden names separately, and hide/restore is admin-gated. The hidden row and any flags using it are preserved, so hiding is reversible.

**Gate the Overview.** The voice agent never sees narrative prose, so after drafting the Overview paragraph, send it through the comprehension gate as a one-item batch: invoke the Task tool with subagent_type `comprehension-gate` and the array `[{"id": 1, "severity": "overview", "location": null, "description": "<overview text>", "proposed_fix": null, "kind": "prose"}]` in a four-backtick `json` fence. On `REWRITE`, you wrote this paragraph, so apply the notes and any `unresolved` entries yourself: replace each unresolved phrase with the concrete behavior it stands for, drop any invented prefix ahead of the first sentence, lead with what the change does, one idea per sentence. Re-check the rewritten paragraph at most once, then proceed with your best version regardless of the second verdict. On any error or malformed response, keep the drafted Overview (fail open). Record usage in `$token_usage["comprehension-gate-overview"]`. In debug mode, save the stage `11e-overview-gate` artifacts (see `review-debug.md`).

**On the `delta` path** (`$review_mode` is `delta`), everything above still governs what you compose, but not where it goes: Read `~/.agents/skills/review-code/handlers/review-carry-forward.md` and follow it instead of saving over `$review_file`. Do not Read the existing review.

Save the complete review to `$review_file`.

**Lint the narrative.** With the file on disk, run the linter over its narrative prose. It reads the Overview and the per-agent summaries and skips finding bodies, which the voice pass already gated. It records what it finds as a `## Lint notes` section at the end of the file and never edits the prose:

```bash
~/.claude/skills/review-code/scripts/lint-review-narrative.py --annotate "$review_file"
```

Re-running is safe: it replaces any section an earlier run left, and drops the section when the prose comes back clean. A nonzero `error` field, or a missing script, leaves the review as composed. On the `delta` path this step runs after the carry-forward merge, against the merged file; `review-carry-forward.md` says where. In debug mode, save the stage `11c2-voice-lint` narrative artifacts (see `review-debug.md`).

Then inform the user with a clickable file link:

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
