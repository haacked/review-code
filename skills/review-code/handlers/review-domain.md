## Domain Reviews

Loaded when `REVIEW_FIELDS.domain_reviews` is a non-empty array. Each entry names a file under `~/.agents/skills/review-code/domain-reviews/` whose trigger matched this diff. A domain review runs the Codex CLI in its own scratch checkout with the change applied, so it can compile and run code to prove a finding. It runs once over the whole patch, also when the review is chunked, and it takes several minutes, so start it before the Claude reviewers and collect it after them.

If an entry has `available: false`, the `codex` CLI is not installed. Tell the user once that the domain review `<name>` was skipped for that reason, record it as a coverage gap, and skip the rest of this handler for that entry.

### Start (before dispatching the domain reviewers)

On a delta re-review, first check that the delta still matches, since the session planned against the whole PR. Run `python3 ~/.agents/skills/review-code/scripts/domain-review.py plan --org "<git.org>" --repo "<git.repo>" --diff-file "$review_diff_path"` and start only the entries it returns.

Run this once per entry, right after `build-agent-briefing.sh` succeeds and before any reviewer dispatch:

```bash
python3 ~/.agents/skills/review-code/scripts/domain-review.py start \
  --session-file "$SESSION_FILE" --name "<entry.name>" --diff-file "$review_diff_path"
```

It returns JSON with `state_path`, `report_name`, `report_path`, and `timeout`, and Codex keeps running after the command exits. Keep `state_path` and `report_name`. The reproduction files Codex writes are copied to `scratch/` beside `state_path` when the run ends. If it exits non-zero, tell the user the reason it printed, record the reason as a coverage gap, and continue without that domain review. Do not register `report_path` in `expected-reviewer-reports.txt`: a failed domain review is a coverage gap, not a failed review.

### Collect (after "Check What Each Agent Actually Read")

Run it with a Bash timeout of 600000 ms. The default Bash timeout stops the command before it can answer.

```bash
python3 ~/.agents/skills/review-code/scripts/domain-review.py wait --state "<state_path>" --max-seconds 540
```

- **`running`**: run the same command again. The runner stops Codex when the domain file's `timeout` passes, and `wait` reports `failed` if the runner has not finished shortly after that, so this loop ends.
- **`done`**: split the report with `reviewer-report.py` as `reviewer-output.md` describes, using the returned `report_path` and `report_name`, and add its findings to the synthesis pool. The source agent is `<report_name>`.
- **`failed`** or **`timed_out`**: tell the user the `error` it printed, record it as a coverage gap in the review's scope section, and continue.

`check-diff-coverage.sh` reads only Claude subagent transcripts, so a domain review never appears in it. Record `$token_usage["<report_name>"]` as `{ total_tokens: 0, tool_uses: 0, duration_ms }` using the `duration_ms` it returned.

If the review stops before the collect step, run `domain-review.py cleanup --state "<state_path>"`. That command stops Codex and removes its scratch checkout.

### Reproduced findings

A domain review's finding often says it was reproduced and names a test or script under `.codex-scratch/`. Such a finding is evidence from running code. Give `finding-validator` the copied file under `scratch/` beside `state_path`, so it can read the reproduction. When the validator dismisses the finding, keep it `blocking` and keep its confidence if that file exists and the validator's reasoning does not show the reproduction is wrong. Apply the normal downgrade when the file is missing or the validator shows the reproduction tests something else. A domain finding the domain reviewer only reasoned about gets the normal validation.
