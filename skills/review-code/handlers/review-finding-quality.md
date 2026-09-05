## Finding Quality Pipeline

Load this handler after finding validation and the optional adversary meta-review. It owns the internal finding contract, fast comprehension preflight, semantic composition, voice polish, final comprehension gate, and executable publication boundary. Its outputs are `$finding_quality = {findings, rewrites_needed, withheld}` and `$finding_publication = {findings, comments, unmapped_comments, withheld, all_withheld, clean}`.

When `$selected_agents` or the surviving finding pool is empty, set `$finding_quality` to `{"findings": [], "rewrites_needed": [], "withheld": []}` and skip to "Finalize Publication". A clean review still needs an explicit value because document composition, `--fix`, and PR output consume it.

### Build and Validate the Contract

Enumerate the surviving findings in stable review order. Assign every finding a unique sequential integer `id`, starting at 1, then read its cited code and relevant diff and build:

```json
{
  "id": 1,
  "agent": "correctness",
  "severity": "blocking",
  "comment_style": "concise",
  "location": "path/file.rs:42",
  "file": "path/file.rs",
  "line": 42,
  "confidence": 90,
  "description": "the reviewer's current body",
  "proposed_fix": "fix text or null",
  "facts": {
    "problem": "the opening domain-level summary of what breaks",
    "trigger": "a specific request, state, or example, or null",
    "mechanism": ["causal step one", "causal step two"],
    "result": "the detailed terminal wrong value or behavior",
    "requested_change": "the concrete code change requested",
    "regression_case": "the regression coverage requested, or null",
    "regression_rationale": "why coverage does not apply, or null"
  }
}
```

`location` is the display value. `file` and `line` are the routing values used by diff mapping, draft comments, and `--fix`; keep them as separate fields through every later merge. A finding without a specific source location cannot cross the publication boundary and remains in the local review's withheld section.

Set `comment_style` from the session (`concise` by default, or `detailed`) on every finding and preserve it through preflight, composition, voice, repair, and the final gate. Style changes public wording only; it never reduces the internal analysis.

The facts are the source of truth. Replace internal labels such as "collector misses it" or "the group remains pending" with what happens to the request, property, value, or caller. Order `mechanism` by execution. Blocking and suggestion findings require `problem`, at least one mechanism step, `result`, and `requested_change`. Blocking findings also require `regression_case`, or `regression_rationale` when coverage does not apply. Questions and nits may leave inapplicable facts null, but `requested_change` must contain the question or small change.

`description` must be a non-empty reviewer body prefixed with its `severity`: `` `blocking`: ``, `` `suggestion`: ``, `` `question`: ``, or `` `nit`: ``. The contract restores missing prefixes and rejects conflicting ones during composition and publication. The contract script never generates public prose from facts. Keep complete evidence, citations, and the concrete code fix in the internal facts and `proposed_fix`. Public bodies need the problem, relevant trigger, and requested change, plus enough explanation to connect them. Preserve the accuracy of included identifiers, values, citations, and code; do not require every internal token or code block in the public body. `description` is the complete public comment. Include a small verified code example when the fix would otherwise be ambiguous, and never append `proposed_fix` automatically.

Write the array to `<artifacts_dir>/finding-contract-input.json`, then run:

```bash
~/.agents/skills/review-code/scripts/finding-comment-contract.py compose \
  "<artifacts_dir>/finding-contract-input.json" \
  > "<artifacts_dir>/finding-contract-validated.json"
```

Keep every `withheld` entry for the local review and remove it from later model calls. Never substitute its reviewer body.

### Fast Comprehension Preflight

Send the validated findings directly to `comprehension-gate` before semantic composition. Give the gate only the finding objects and facts, with no diff, briefing, or source-code path. Use the same response parsing and fail-closed coverage rules as the final gate, then run `finding-comment-contract.py gate` without `--final` to produce `<artifacts_dir>/finding-preflight.json`.

`PASS` findings bypass `code-reviewer-comment`. Reset their `publishable` value to false and set `quality_state` to `preflight_passed`; the final gate still decides whether they are safe to publish after the voice pass. Apply the same style-aware meaning and included-token preservation checks required after composition. Concise preflight must reject unnecessary walkthroughs even when all facts have coverage.

`REWRITE` findings go through `code-reviewer-comment` in one batch. A missing, duplicate, malformed, or error preflight verdict is a `gate_error` and stays withheld. Do not send it to the composer and do not restore the reviewer body.

Record preflight usage under `$token_usage["comprehension-gate-preflight"]`. In debug mode, save the input, raw verdicts, parsed verdicts, pass set, rewrite set, and withheld entries under `11b1-comprehension-preflight`.

### Compose Rewrite Bodies

If the preflight produced no `rewrites_needed` entries, skip the composer call and record zero composer usage. Otherwise send only those entries to `code-reviewer-comment` with their current bodies, facts, preflight coverage, notes, unresolved phrases, `$diff_path`, `<artifacts_dir>/briefing.md`, and `$file_access_instructions`. The composer must compose from the facts and inspect cited code when a fact still uses internal shorthand.

- **Claude:** start a Task with subagent_type `code-reviewer-comment`.
- **Codex:** write a self-contained prompt to `<artifacts_dir>/comment-compose-prompt.md`, then run `agent-dispatch.sh run code-reviewer-comment <prompt-file> <artifacts_dir>/comment-compose-output.md`.

Parse by id and merge only `description` and `proposed_fix`. Ignore unknown extra ids and record a parse anomaly. Withhold each expected id that is missing, duplicated, malformed, or has a non-null `error`, using `quality_state: "composition_failed"` and the concrete reason.

Accept a response only when it preserves the exact severity prefix, accurately states the problem and relevant trigger, and keeps the requested change and actionable fix equivalent. Included identifiers, citations, exact values, and code excerpts must stay exact, but internal tokens and code blocks need not all appear in public. Keep the full internal `proposed_fix` unchanged unless explicitly repairing its prose. A failure is withheld; the reviewer draft is never restored.

Run `finding-comment-contract.py compose` again on successfully merged rewrite entries. Merge those composed entries with the preflight `PASS` entries. Set `$finding_quality` to that result, then append every earlier `invalid_contract`, `gate_error`, and `composition_failed` entry to `$finding_quality.withheld`. No later assignment may discard a withheld entry.

Record composer usage under `$token_usage["code-reviewer-comment"]`. In debug mode, save the contract, prompt, raw output, merged entries, and withheld decisions under `11b2-semantic-composition`.

### Voice Pass

Send each finding's `id`, `severity`, `location`, `comment_style`, `description`, and `proposed_fix` to `code-reviewer-voice`. Keep the facts and routing fields in `$finding_quality`, outside the voice payload.

Parse responses by id. `unchanged: true` keeps the current body. Ignore unknown ids and count them as anomalies. A missing id keeps the current body. Treat an array length difference greater than one as a failed batch and keep every current body.

For each rewrite, require the identical severity prefix, every backtick-quoted path or line token from the current body, and every code block. Limit growth to about twice the original length. Rejecting a voice rewrite restores the pre-voice body. If more than half fail, discard the whole voice batch.

Run `~/.agents/skills/review-code/scripts/gate-voice-lint.py` over all surviving bodies. For warned ids, ask the same voice agent once to repair the flagged sentence. Claude may resume the voice task. Codex must dispatch a fresh, self-contained `code-reviewer-voice` prompt because it has no resume state. Recheck preservation and lint once. A remaining warning restores the pre-voice body. A missing linter or linter error leaves the accepted voice bodies unchanged.

Record voice usage, preservation failures, and `{total_tokens: 0, checked, clean, warned, bounced, reverted}` under the existing `$token_usage` keys. In debug mode, save `11c-voice-rewrite` and `11c2-voice-lint` artifacts.

### Final Comprehension Gate

Merge accepted voice bodies into `$finding_quality.findings`. Write the full object to `<artifacts_dir>/finding-contract-voiced.json` and its `findings` array to `<artifacts_dir>/comprehension-input.json` with `kind: "finding"`.

- **Claude:** start a Task with subagent_type `comprehension-gate` and the input.
- **Codex:** point a self-contained prompt at `<artifacts_dir>/comprehension-input.json`, then run `agent-dispatch.sh run comprehension-gate <prompt-file> <artifacts_dir>/comprehension-output.md`. The gate may read that input file, but receives no diff or source-code path.

Extract the JSON array to `<artifacts_dir>/comprehension-verdicts.json`, then run:

```bash
~/.agents/skills/review-code/scripts/finding-comment-contract.py gate \
  "<artifacts_dir>/finding-contract-voiced.json" \
  "<artifacts_dir>/comprehension-verdicts.json" \
  > "<artifacts_dir>/finding-gate-first.json"
```

The script accepts `PASS` only when the selected style's required facts have coverage and `inference_required` is false. Concise requires problem, applicable trigger, and requested change; mechanism, result, and regression coverage may be false. Detailed requires every applicable field. The model must also reject factual inconsistency, unclear action, or prose that violates the selected style. Missing, duplicate, or malformed verdicts are withheld with `quality_state: "gate_error"`.

For each `rewrites_needed` entry, start a fresh `code-reviewer-comment` invocation under both harnesses. Give it the structured finding, current body, gate coverage, notes, unresolved phrases, `$diff_path`, briefing path, and file-access instructions. Never resume the original reviewer.

Apply the composer preservation and error checks, run `compose` on successful repairs, cold-read them once more, then apply `gate --final`. A second `REWRITE`, malformed verdict, composer error, or preservation failure is withheld. Never restore a pre-gate opaque body.

Send both the preflight `PASS` findings and the composed `REWRITE` findings through the final comprehension gate. Merge first-pass findings, second-pass findings, and every withheld array into `$finding_quality`. Record `{total_tokens: 0, contracted, preflight_passed, composed, gate_passed, rewritten, withheld, gate_errors}` under `$token_usage["finding-quality"]`, plus usage for the preflight, final gate, and repair calls. In debug mode, save the stage under `11c3-comprehension-gate`.

### Finalize Publication

If `review-pr-output.md` was loaded, run its "Link File References in Comment Bodies" step now against `$finding_quality.findings`. Linkification happens after every semantic check but before the executable publication snapshot.

Write `$finding_quality` to `<artifacts_dir>/finding-quality-final.json`, then run:

```bash
~/.agents/skills/review-code/scripts/finding-comment-contract.py publish \
  "<artifacts_dir>/finding-quality-final.json" \
  > "<artifacts_dir>/finding-publication.json"
```

Read that result as `$finding_publication`. Use only its `comments` and `unmapped_comments` arrays for the draft. Keep its `withheld` array in the local review. Its `findings` array is the only input to `--fix`, review composition, Suggested Comments, and any other publication path. If `all_withheld` is true, replace an existing pending review with an empty one. If `clean` is true, handle the review as a clean result rather than a semantic failure.

The `publish` command fails closed when a candidate is not explicitly publishable, lacks a non-empty body, or lacks valid `file` and `line` routing. It moves that entry to `withheld` with `quality_state: "publication_failed"`; later steps must not reconstruct a comment from the earlier object.
