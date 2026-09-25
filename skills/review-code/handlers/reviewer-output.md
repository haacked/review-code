# Save Reviewer Evidence

Apply this contract to domain reviewers, including each chunk reviewer and coverage retry. Keep the findings' fenced bodies and `Location: path:line | Confidence: NN%` trailers unchanged.

Give each dispatch a unique `$report_name`, such as `code-reviewer-security`, `chunk-2-code-reviewer-security`, or `coverage-bounce-1`. Set `$report_path` to `<artifacts_dir>/reports/$report_name.json`. The shared briefing contains the report schema. Put only the report path, report name, and harness in the dispatch prompt; do not copy the schema into every prompt.

Register each expected report before its first dispatch, including chunk reviewers and coverage retries. Reuse the same entry when retrying a dispatch at the same path:

```bash
manifest="<artifacts_dir>/expected-reviewer-reports.txt"
if [[ ! -f "$manifest" ]] || ! grep -Fxq -- "$report_path" "$manifest"; then
    printf '%s\n' "$report_path" >> "$manifest"
fi
```

For Codex, pass `$report_path` as the output-file argument to `agent-dispatch.sh run`. Its compact result names the report and event-log files; do not read the event log or raw report into the conversation. For the Claude fallback, save the returned JSON to `$report_path` using the Write tool, with content separate from the path. Never interpolate agent output into shell commands.

After each successful dispatch, split the saved report:

```bash
python3 ~/.agents/skills/review-code/scripts/reviewer-report.py \
  --input "$report_path" \
  --output-dir "<artifacts_dir>" \
  --name "$report_name"
```

Require success before accepting the result. A missing, malformed, or unavailable report is a failed review, never a clean review. For `BRIEFING_UNAVAILABLE`, follow the existing briefing-repair procedure and retry using this same output contract.

Read only the returned `findings_path` for synthesis. Retain the returned coverage counts and every named gap; disclose unresolved gaps in the review. An empty findings file is valid only after the splitter succeeds. Keep `investigation_path` and `coverage_path` for the local review and debugging. Read a specific investigation only when needed to resolve an identified finding or coverage question.

The saved investigation is a complete record. The compose step retains a copy beside the review and links it from the agent's section before session cleanup. Coverage retries use distinct report names so their evidence survives alongside the first pass.
