# Finalize reviewer routing

Run the classifier after the full-diff explorer completes. Pass the context artifact by path; do not read its body into the conversation.

```bash
routing_args=("$SESSION_FILE" --diff-file "$review_diff_path" --explorer-context "$architectural_context_path")
if [[ -n "${area:-}" ]]; then
  routing_args+=(--area "$area")
fi
~/.agents/skills/review-code/scripts/classify-review-scope.sh "${routing_args[@]}" \
  > "<artifacts_dir>/review-routing.json"
```

Read the resulting JSON and replace `$selected_agents`, `$skipped_agents`, and `$classification_reasoning` with `agents`, `skipped_agents`, and `reasoning`. Retain `agent_decisions` for the scope report. Correctness always runs. Every specialist runs unless its entry has `status: not_applicable` and concrete negative evidence. Missing, unreadable, malformed, or uncertain evidence keeps the relevant reviewer enabled. If the classifier fails, rerun without `--explorer-context` while retaining `--area "$area"` when an area was requested. If that also fails, stop and report the failure.

For a user-requested `area`, the classifier selects the requested reviewer and correctness without duplicates. It records every other reviewer as excluded by the explicit user scope override. The requested reviewer runs even if the explorer marked it not applicable. These user exclusions carry no negative evidence.

Use this selection for an unchunked review, including a delta dispatch. Its explorer evidence must describe `$review_diff_path`, the same patch the reviewers receive. Do not derive another selection from diff size, file types, or missing scoped diffs.

For a chunked review, this selection describes the whole patch and controls only the shared exploration. Each chunk analysis produces its own routing evidence, and the chunk handler runs this classifier again against that chunk's patch and analysis. A chunk may skip a specialist only when its own explorer supplied concrete negative evidence. Correctness always runs in every chunk.

Tell the user which reviewers were skipped and why. At composition, retain `review-routing.json` beside the reviewer coverage artifacts and include each skip reason and its evidence in the review's scope section. Link the saved artifact for the complete decision record. On append, report this run's decisions separately from earlier scope records.
