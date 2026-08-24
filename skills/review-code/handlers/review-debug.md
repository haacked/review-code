## Debug Mode

Loaded when the session JSON's `debug_session_dir` is a non-empty string. Store it as `$debug_session_dir`. These instructions add artifact writes to the review flow in `review.md`; execute each stage's writes when the flow reaches that stage.

Debug writes must never block or fail the review: if a write fails, ignore the error and continue. Each write is a single Bash call to the bridge script.

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

**Stages to instrument:**

- **07-scope-classification**: Save the classifier output as `classification.json` (the full JSON from `classify-review-scope.sh`).
- **08-context-explorer**: Record timing (start/end). Save the explorer prompt as `prompt.md` and the result (`$architectural_context`) as `result.md`.
- **09-per-chunk-analysis** (chunked reviews only): Record timing (start/end). For each chunk, save the prompt as `chunk-{id}-prompt.md` and result as `chunk-{id}-result.md`.
- **10-agent-dispatch**: Record timing (start/end). For each agent (or chunk x agent combination), save the prompt as `{agent}-prompt.md` (or `chunk-{id}-{agent}-prompt.md`) and result as `{agent}-result.md` (or `chunk-{id}-{agent}-result.md`). Save stats with agent count.
- **11-synthesis**: Record timing (start/end). Save the merged findings as `merged-findings.md` and corroboration results as `corroboration.md`.
- **11b-adversary-meta-review** (adversary pass only): Record timing (start/end). Save the input payload as `input.json`, the raw adversary output as `raw-output.md`, and the parsed JSON response as `response.json`. On timeout or error, also save `stderr.log` (from the `<engine>_stderr` field, e.g. `copilot_stderr` or `codex_stderr`) and `log-path.txt` (from the `<engine>_log` field). When the adversary's reasoning adjusts a finding's body, save the original `description`, the new `description`, and the adversary's reasoning as `adjusted-{finding_id}.json` so the change is auditable.
- **11b2-comprehension-gate**: Record timing (start/end). Save the input items as `input.json`, the agent's raw response as `raw-output.md`, the parsed verdicts as `verdicts.json`, each bounce request and result as `bounce-{id}-request.md` and `bounce-{id}-result.md`, and the per-finding outcomes as `decisions.json` (per finding `{id, verdict, bounced, accepted, reason}`; this is the artifact to inspect when evaluating whether the gate is helping).
- **11c-voice-rewrite**: Record timing (start/end). Save the input findings as `input.json`, the agent's raw response as `raw-output.md`, the parsed rewrites as `output.json`, a side-by-side comparison of original vs. rewritten descriptions as `comparison.md` (markdown table or sequential blocks; this is the artifact to inspect when evaluating whether the voice pass is helping), and the per-finding accept/reject decisions as `validation.json` (per-finding `{accepted: true|false, reason: "..."}` from the preservation checks).
- **11c2-voice-lint**: Save the bodies handed to `gate-voice-lint.py` as `input.json`, its result as `output.jsonl` (one JSON object per warned finding), and the per-finding outcomes as `decisions.json` (per finding `{id, warned, bounced, accepted, reverted, categories}`; this is the artifact to inspect when deciding whether the lint gate is reverting more than it fixes). When a bounce ran, save its request and result as `bounce-{id}-request.md` and `bounce-{id}-result.md`. Later in the run, at the compose step, save the narrative linter's JSON result as `narrative-report.json` and the `## Lint notes` section it wrote as `narrative-notes.md`.
- **11d-fix-pass** (fix pass only): Save `classification.json` (per-finding `{id, status, reason?, choice?}` decisions), `edits.json` (per-edit `{finding_id, file, line, before_excerpt, after_excerpt}` capturing what was changed), and `outcomes.json` (the final `$fix_outcomes` map).
- **11e-overview-gate**: Save the one-item input as `input.json` and the gate's verdict as `verdict.json`. If the Overview was rewritten, save the drafted and final paragraphs as `before-after.md`.
- **12-token-usage**: After the review is complete, save per-agent token usage and aggregate totals. Build a JSON object from `$token_usage` and save via the bridge:

```bash
jq -n --argjson agents '<JSON object with per-agent {total_tokens, tool_uses, duration_ms}>' \
  --arg total '<total_tokens sum>' --arg count '<step_count>' \
  --arg dir "$debug_session_dir" \
  '{"action":"stats","debug_dir":$dir,"stage":"12-token-usage","data":{"agents":$agents,"total_tokens":($total|tonumber),"step_count":($count|tonumber),"agent_count":($count|tonumber)}}' \
  | ~/.claude/skills/review-code/scripts/debug-artifact-writer.sh
```
