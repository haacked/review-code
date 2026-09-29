# Finalize reviewer routing

Run the classifier after the full-diff explorer completes. Pass the context artifact by path; do not read its body into the conversation.

```bash
~/.agents/skills/review-code/scripts/classify-review-scope.sh "$SESSION_FILE" \
  --explorer-context "$architectural_context_path" > "<artifacts_dir>/review-routing.json"
```

Read the resulting JSON and replace `$selected_agents`, `$skipped_agents`, and `$classification_reasoning` with `agents`, `skipped_agents`, and `reasoning`. Retain `agent_decisions` for the scope report. Correctness always runs. Every specialist runs unless its entry has `status: not_applicable` and concrete negative evidence. Missing, unreadable, malformed, or uncertain evidence keeps the relevant reviewer enabled. If the classifier fails, rerun without `--explorer-context` to save the default decisions for all nine reviewers. If that also fails, stop and report the failure.

For a user-requested `area`, select correctness and the requested area, removing duplicates. Mark all other areas as skipped because the user requested a narrower review, even when the explorer recommended them. Update the saved JSON's `agents`, `skipped_agents`, `reasoning`, and `agent_decisions` to reflect this explicit override. The requested reviewer runs even if the explorer marked it not applicable. Never describe these user exclusions as negative evidence.

Use this selection for the full review, including every chunk and delta dispatch. Chunk analysis does not remove reviewers. Do not derive another selection from diff size, file types, or missing scoped diffs.

Tell the user which reviewers were skipped and why. At composition, retain `review-routing.json` beside the reviewer coverage artifacts and include each skip reason and its evidence in the review's scope section. Link the saved artifact for the complete decision record. On append, report this run's decisions separately from earlier scope records.
