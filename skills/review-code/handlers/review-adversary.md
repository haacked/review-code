## Adversary Meta-Review

Loaded when `adversary` is present in the session JSON, meaning the user opted in with `--adversary:copilot` or `--adversary:codex`. This pass runs after "Validate Findings Against the Diff" and before the Voice Pass: it gives the adversary engine a focused task — validate Claude's findings and scan the diff for anything glaringly obvious that was missed.

If `adversary.available` is false (the flag was given but that engine's CLI isn't installed): tell the user once — "Adversary review requested via `--adversary:$engine` but the `$engine` CLI isn't installed; skipping." — then skip the rest of this pass.

Otherwise, let `$engine` be `adversary.engine` (`"copilot"` or `"codex"`) and continue below.

**Build the findings payload.** Collect all findings that survived synthesis and validation into a JSON array. For each finding, include: a sequential `id` (starting at 1), `agent` (source agent name), `type` (blocking/suggestion/nit/question), `file`, `line`, `description`, `proposed_fix` (if any), and `confidence`.

**Dispatch the meta-review:**

```bash
jq -n \
  --argjson findings '<findings JSON array>' \
  --arg diff "$diff" \
  --argjson timeout_seconds 300 \
  '$ARGS.named' | ~/.claude/skills/review-code/scripts/$engine-meta-review.sh
```

Where `$diff` is the full diff from session data, `<findings JSON array>` is the JSON array of surviving findings, and `$engine` selects `copilot-meta-review.sh` or `codex-meta-review.sh`. Use `jq` to safely encode both as JSON.

Save the JSON output as `$adversary_meta_review`. In debug mode, save the stage `11b-adversary-meta-review` artifacts (see `review-debug.md`).

**Integrate meta-review results:**

If `$adversary_meta_review` has `available: true`, `timed_out: false`, and no `error` field:

All updates below are to synthesis-time metadata (corroboration flag, confidence, severity). Do NOT modify the finding's `description` or `proposed_fix` text to record any of this. See "Comment Body Hygiene" in `review.md`.

1. **Process validations.** For each entry in `validations`:
   - **CONFIRMED**: Mark the matching finding as cross-model corroborated (metadata only). Boost confidence by 15 percentage points (capped at 95%).
   - **DISMISSED**: If the finding is `blocking:`, downgrade to `suggestion:`. Do NOT remove the finding entirely; Claude's analysis takes precedence. The adversary's dissenting reasoning is debug data only: log it under the `11b-adversary-meta-review` debug stage if `$debug_session_dir` is set, but do not embed it in the comment body.
   - **ADJUSTED**: If the adversary's reasoning, read in isolation, would cause a competent reviewer to change what they write in the comment (a different line number, an additional condition, a revised failure description), incorporate it into the body as if it were your own analysis and do not annotate the change with attribution to `$engine`. If the reasoning only evaluates the finding's validity or tone without adding technical content, ignore it. When you do adjust the body, save the debug artifact noted in `review-debug.md` so the change is auditable.
   - If a `finding_id` does not match any surviving finding, ignore it silently.

2. **Process missed issues.** For each entry in `missed_issues`:
   - Apply the same scope filter: drop any that reference files not in `IN_SCOPE_PATHS`.
   - For surviving missed issues, add them to the finding pool with `agent: $engine` (metadata) and the type from the meta-review output. The `description` reads as a normal review finding; do not tag it with "(flagged by Copilot)"/"(flagged by Codex)" or any similar attribution.
   - These are subject to the same filtering thresholds as Claude findings. Since they come from a single source (the adversary engine), they are solo findings and need confidence >= 40% to be included (unless they are questions/nits). Assign a default confidence of 50% to adversary missed issues.

3. **Corroboration rule.** Cross-model corroboration (Claude + adversary CONFIRMED) counts as corroboration even if only one Claude agent flagged the issue.

**Error handling:** If the script returns `available: false`, `timed_out: true`, or contains an `error` field, ignore the meta-review result and continue with Claude-only findings. Never fail or stop the review because of an adversary-engine error.

Record `adversary_meta_review` in `$token_usage` with `{ total_tokens: 0, tool_uses: 0, duration_ms }` using the `duration_ms` value from the output.
