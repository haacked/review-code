## Finding Quality Pipeline

Load this handler after finding validation and the optional adversary meta-review. It owns the internal finding contract, fast comprehension preflight, semantic composition, wording lint, final comprehension gate, and executable publication boundary. Its outputs are `$finding_quality = {findings, rewrites_needed, withheld}` and `$finding_publication = {findings, comments, unmapped_comments, withheld, all_withheld, clean}`.

When `$selected_agents` or the surviving finding pool is empty, set `$finding_quality` to `{"findings": [], "rewrites_needed": [], "withheld": []}` and skip to "Finalize Publication". A clean review still needs an explicit value because document composition, `--fix`, and PR output consume it.

### Deliver Finding Inputs

For every model call in this handler, including repairs, save the stage's input array to `<artifacts_dir>/$quality_stage-input.json`. Preserve exactly the fields required below. Set `$quality_agent` to the named agent and use a distinct `$quality_stage` for each invocation, such as `finding-preflight`, `comment-compose`, `lint-repair`, `comprehension`, `comment-repair-1`, or `comprehension-recheck-1`. Extract arrays from existing JSON artifacts with `jq` when possible; never paste them into dispatch prompts.

Before the first composer call, save the prepared `$file_access_instructions` once to `<artifacts_dir>/file-access.md` using Write, with content separate from the path. Generate each prompt with:

```bash
quality_input="<artifacts_dir>/$quality_stage-input.json"
quality_prompt="<artifacts_dir>/$quality_stage-prompt.md"
quality_output="<artifacts_dir>/$quality_stage-output.md"
quality_context_args=()
if [[ "$quality_agent" == code-reviewer-comment ]]; then
    quality_context_args=(--diff "$diff_path" --briefing "<artifacts_dir>/briefing.md" --file-access "<artifacts_dir>/file-access.md")
fi
python3 ~/.agents/skills/review-code/scripts/build-finding-prompt.py \
  --agent "$quality_agent" --input "$quality_input" "${quality_context_args[@]}" \
  > "$quality_prompt"
```

Require success before dispatch. The helper validates the input, supplies counts for complete reads, and rejects prompts of 4096 bytes or more. It includes source-context paths only for the composer. The limit covers the generated dispatch prompt, not the harness-supplied agent definition or the input file.

- **Claude:** Read only the generated prompt and pass it unchanged to Task with `subagent_type: $quality_agent`. Apply the named-agent fallback from `review.md` if needed.
- **Codex:** Run `~/.agents/skills/review-code/scripts/helpers/agent-dispatch.sh run "$quality_agent" "$quality_prompt" "$quality_output"` and read its output file for response parsing.

Do not append finding bodies, facts, fixes, or lint notes to either prompt. Repair inputs belong in a fresh file too. If generation fails or an agent returns `INPUT_UNAVAILABLE`, handle it as that stage's existing error case: withhold composer and gate inputs, or keep the current bodies on a lint repair failure. Never interpret unavailable input as an empty or passing result. The reviewer-only `BRIEFING_UNAVAILABLE` inline fallback does not apply here.

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
  "side": "RIGHT",
  "confidence": 90,
  "validator_confirmed": true,
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

Set `validator_confirmed` to `true` only on a `blocking` finding that `finding-validator` returned as CONFIRMED, and to `false` otherwise, including when the validator was unreachable. The final gate uses it to keep a confirmed blocking finding in the draft.

`location` is the display value. `file`, `line`, and `side` are the routing values used by diff mapping and draft comments; keep them as separate fields through every later merge. Preserve the side from finding validation: `LEFT` uses old-file line numbers, and `RIGHT` uses new-file line numbers. For `--fix`, inspect the current code before applying a change at a `LEFT` location. A finding without a specific source location cannot cross the publication boundary and remains in the local review's withheld section.

Set `comment_style` from the session (`concise` by default, or `detailed`) on every finding and preserve it through preflight, composition, lint repair, gate repair, and the final gate. Style changes public wording only; it never reduces the internal analysis.

The facts are the source of truth. Replace internal labels such as "collector misses it" or "the group remains pending" with what happens to the request, property, value, or caller. Order `mechanism` by execution. Blocking and suggestion findings require `problem`, at least one mechanism step, `result`, and `requested_change`. Blocking findings also require `regression_case`, or `regression_rationale` when coverage does not apply. Questions and nits may leave inapplicable facts null, but `requested_change` must contain the question or small change.

`description` must be a non-empty reviewer body prefixed with its `severity`: `` `blocking`: ``, `` `suggestion`: ``, `` `question`: ``, or `` `nit`: ``. The contract restores missing prefixes and rejects conflicting ones during composition and publication. The contract script never generates public prose from facts. Keep complete evidence, citations, and the concrete code fix in the internal facts and `proposed_fix`. Preserve the accuracy of included identifiers, values, citations, and code; do not require every internal token or code block in the public body. `description` is the complete public comment; never append `proposed_fix` automatically.

Write the array to `<artifacts_dir>/finding-contract-input.json`, then run:

```bash
~/.agents/skills/review-code/scripts/finding-comment-contract.py compose \
  "<artifacts_dir>/finding-contract-input.json" \
  > "<artifacts_dir>/finding-contract-validated.json"
```

Keep every `withheld` entry for the local review and remove it from later model calls. Never substitute its reviewer body.

### Fast Comprehension Preflight

Extract the validated `findings` array into `<artifacts_dir>/finding-preflight-input.json` and dispatch `comprehension-gate` with `$quality_stage = finding-preflight` before semantic composition. Give the gate only that input file, with no diff, briefing, or source-code path. Use the same response parsing and fail-closed coverage rules as the final gate, then run `finding-comment-contract.py gate` without `--final` to produce `<artifacts_dir>/finding-preflight.json`.

`PASS` findings bypass `code-reviewer-comment`. Reset their `publishable` value to false and set `quality_state` to `preflight_passed`; the wording lint can still send them to the composer, and the final gate decides whether they are safe to publish. Apply the same style-aware meaning and included-token preservation checks required after composition. Concise preflight must reject a body that carries more than the problem, the change, and code the author would otherwise write, even when all facts have coverage.

`REWRITE` findings go through `code-reviewer-comment` in one batch. A missing, duplicate, malformed, or error preflight verdict is a `gate_error` and stays withheld. Do not send it to the composer and do not restore the reviewer body.

Record preflight usage under `$token_usage["comprehension-gate-preflight"]`. In debug mode, save the input, raw verdicts, parsed verdicts, pass set, rewrite set, and withheld entries under `11b1-comprehension-preflight`.

### Compose Rewrite Bodies

If the preflight produced no `rewrites_needed` entries, skip the composer call and record zero composer usage. Otherwise save only those entries, including their current bodies, facts, `reasons`, and the gate's unresolved phrases, to `<artifacts_dir>/comment-compose-input.json`. Dispatch `code-reviewer-comment` with `$quality_stage = comment-compose` through "Deliver Finding Inputs". The composer must compose from the facts and inspect cited code when a fact still uses internal shorthand.

Parse by id and merge only `description` and `proposed_fix`. Ignore unknown extra ids and record a parse anomaly. Withhold each expected id that is missing, duplicated, malformed, or has a non-null `error`, using `quality_state: "composition_failed"` and the concrete reason.

Accept a response only when it preserves the exact severity prefix, accurately states the problem and relevant trigger, and keeps the requested change and actionable fix equivalent. Included identifiers, citations, exact values, and code excerpts must stay exact, but internal tokens and code blocks need not all appear in public. Keep the full internal `proposed_fix` unchanged unless explicitly repairing its prose. A failure is withheld; the reviewer draft is never restored.

Run `finding-comment-contract.py compose` again on successfully merged rewrite entries. Merge those composed entries with the preflight `PASS` entries. Set `$finding_quality` to that result, then append every earlier `invalid_contract`, `gate_error`, and `composition_failed` entry to `$finding_quality.withheld`. No later assignment may discard a withheld entry.

Record composer usage under `$token_usage["code-reviewer-comment"]`. In debug mode, save the contract, prompt, raw output, merged entries, and withheld decisions under `11b2-semantic-composition`.

### Wording Lint

Lint every body before the final gate: the preflight `PASS` bodies and the composed bodies. Write `$finding_quality` to `<artifacts_dir>/finding-quality-composed.json`, then run:

```bash
~/.agents/skills/review-code/scripts/gate-voice-lint.py \
  --repair-input "<artifacts_dir>/lint-repair-input.json" \
  "<artifacts_dir>/finding-quality-composed.json" \
  > "<artifacts_dir>/voice-lint-result.json"
jq '{checked, clean, warned, repair_ids, error}' "<artifacts_dir>/voice-lint-result.json"
```

The linter exits zero even on errors. `repair_ids` lists the bodies with a warning other than `concise_length`. A body that is only too long goes to the final gate as it is, because the gate judges length and sends a long body back for a trim. When `repair_ids` is empty or `error` is non-null, continue to the final gate with the bodies unchanged. Otherwise `lint-repair-input.json` holds those findings, each with its lint warnings as `reasons` and without the preflight's `unresolved` phrases, which composition already addressed.

Dispatch `code-reviewer-comment` with `$quality_stage = lint-repair` through "Deliver Finding Inputs". Merge and check its bodies as "Compose Rewrite Bodies" does, then run `finding-comment-contract.py compose` on the accepted repairs and replace those ids in `$finding_quality.findings`. A repair that is missing, duplicated, malformed, carries a non-null `error`, fails the preservation checks, or is withheld by `compose` keeps the body it replaced, because that body already passed preflight or composition. Do not lint or repair again; the final gate judges the result.

Record composer usage under `$token_usage["lint-repair"]` and `{total_tokens: 0, checked, clean, warned, repaired}` under `$token_usage["voice-lint"]`. In debug mode, save the lint result, the repair input, raw output, and merge decisions under `11c-wording-lint`.

### Final Comprehension Gate

Write `$finding_quality`, with any accepted lint repairs, to `<artifacts_dir>/finding-contract-linted.json` and its `findings` array to `<artifacts_dir>/comprehension-input.json` with `kind: "finding"`.

Dispatch `comprehension-gate` with `$quality_stage = comprehension` through "Deliver Finding Inputs". The gate may read that input file, but receives no diff or source-code path.

Require the `comprehension-gate` agent's Output schema for both preflight and final verdicts. Write only the parsed JSON array, without Markdown fences, to `<artifacts_dir>/comprehension-verdicts.json`. Each entry must preserve its input `id` and contain `verdict`, `coverage`, `inference_required`, `unresolved`, and `notes`, plus an optional boolean `trim_only`. Coverage has exactly six boolean keys: `problem`, `trigger`, `mechanism`, `result`, `requested_change`, and `regression_case`. Then run:

```bash
~/.agents/skills/review-code/scripts/finding-comment-contract.py gate \
  "<artifacts_dir>/finding-contract-linted.json" \
  "<artifacts_dir>/comprehension-verdicts.json" \
  > "<artifacts_dir>/finding-gate-first.json"
```

The script accepts `PASS` only when the selected style's required facts have coverage and `inference_required` is false. Concise requires problem, applicable trigger, and requested change; mechanism, result, and regression coverage may be false. Detailed requires every applicable field. The model must also reject factual inconsistency, unclear action, or prose that violates the selected style. Missing, duplicate, or malformed verdicts are withheld with `quality_state: "gate_error"`. Missing or extra coverage keys and non-boolean values are malformed in either style.

For each `rewrites_needed` entry, save a one-item array with the structured finding, current body, `reasons`, and the gate's unresolved phrases to `<artifacts_dir>/comment-repair-<id>-input.json`. Dispatch a fresh `code-reviewer-comment` invocation through "Deliver Finding Inputs" with `$quality_stage = comment-repair-<id>` under both harnesses. Never resume the original reviewer.

Apply the composer preservation and error checks, run `compose` on successful repairs, then save each repaired input array to `<artifacts_dir>/comprehension-recheck-<id>-input.json`. Cold-read it once more through "Deliver Finding Inputs" with `comprehension-gate` and `$quality_stage = comprehension-recheck-<id>`, then apply `gate --final`. A malformed verdict, composer error, or preservation failure is withheld. A second `REWRITE` is withheld too, with two exceptions. A finding with `validator_confirmed: true` gets one more repair (see below). A concise `REWRITE` marked `trim_only` with no unresolved phrases publishes when its required coverage passes, and `gate --final` records the trim notes in `reasons`. Never restore a pre-gate opaque body.

A finding with `validator_confirmed: true` is not withheld for its wording. On a second `REWRITE`, `gate --final` returns it in `rewrites_needed` with `quality_state: "blocking_repair_required"`, `two_sentence_limit: true`, and `comment_style: "concise"`. Repair each one exactly as above with `$quality_stage = comment-repair-blocking-<id>`, keeping those fields on the input item, recheck it with `$quality_stage = comprehension-recheck-blocking-<id>`, and apply `gate --final` again. A third `REWRITE` publishes the repaired body with `quality_state: "published_over_gate"` and the gate's reasons in `reasons`. A composer error, preservation failure, or malformed verdict is still withheld.

Send both the preflight `PASS` findings and the composed `REWRITE` findings through the final comprehension gate. Merge first-pass findings, second-pass findings, blocking-repair findings, and every withheld array into `$finding_quality`. A `rewrites_needed` entry that went through the blocking repair is replaced by its recheck result, not merged. Record `{total_tokens: 0, contracted, preflight_passed, composed, gate_passed, rewritten, published_over_gate, withheld, gate_errors}` under `$token_usage["finding-quality"]`, plus usage for the preflight, final gate, and repair calls. In debug mode, save the stage under `11c2-comprehension-gate`.

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
