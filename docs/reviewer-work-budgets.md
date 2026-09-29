# Reviewer search and tool budgets

Domain reviewers stop new investigation after 60 tool calls or 30 searches. They keep verified findings and name the paths, symbols, or checks they could not finish. The saved review, completion message, and draft summary disclose those gaps with the reviewer name and budget counts. A chunk reviewer has its own budget; delivery retries and coverage retries retain that assignment's counts.

These limits are instructions that reviewers follow and report themselves. They do not impose a process timeout or validate counts against a transcript. Report validation rejects missing accounting on new reviews, invalid counters, and limited reports without a reached limit and nonempty gaps. The reviewer must name the actual unfinished check; the validator cannot determine whether a gap description is accurate. Historical reports remain readable without `--require-budget`.

## Choosing the defaults

The September 28 sample uses `bin/token-report --prompts --all-stages --since 2026-09-01 --json` with the default `--match review` filter. It contains 502 domain reviewer transcripts dated September 1 through September 28. Distinct assistant `tool_use` IDs were counted once per transcript. Search calls were identified by `Grep`, `Glob`, or `WebSearch`, or a Bash command containing `rg`, `grep`, or `find` as a word.

| Work per reviewer | Median | p90 | p95 | Maximum | Default limit |
| --- | ---: | ---: | ---: | ---: | ---: |
| Tool calls | 21 | 39 | 46 | 90 | 60 |
| Search calls | 9 | 20 | 23 | 47 | 30 |

Six transcripts reached 60 tool calls, ten reached 30 search calls, and eleven reached either threshold (2.2% of the sample). Both limits sit above the observed 95th percentile to leave most existing reviews room to finish. The goal is to stop unusually long investigations while showing exactly which checks remain unfinished.

The historical count includes report-delivery tools, whereas the policy exempts final report delivery. The search measurement counts matching shell calls, whereas the policy counts each distinct query within a call. Compound commands and mentions of command names can therefore differ from the policy's count. Resumed transcript work is counted together. The corpus covers named Claude domain reviewers, not generic fallback agents or Codex subprocesses. These figures guide conservative starting values; they are not a calibrated cost ceiling.

## Cost and coverage tradeoffs

The policy is generated once into the shared briefing from the same constants used by report validation. It adds instruction text and a small coverage object to every reviewer. Dispatch prompts still reference files. Tool and search counts are proxies for work, not token or dollar limits: one query can return a large result, and reasoning costs can vary without another tool call.

Reviewers read the supplied context and assigned diff first, then investigate their domain. At a limit, they must stop new calls, preserve verified findings, name every pending check including unread diff ranges, and deliver a complete report. Unverified hypotheses become coverage gaps rather than speculative findings. A completed review that happens to finish exactly at a threshold remains valid. In-flight overshoots must report limited coverage. Automatic retries never reset the budget or continue an already limited assignment.

The saved limitations fragment comes from the validated report and carries the dispatch name, so `chunk-2-code-reviewer-correctness` and a retry of that reviewer remain distinguishable. Limitations are retained beside the review before session cleanup. An empty findings file never cancels a coverage gap.

No before/after review-cost reduction is claimed. The historical cost report is a baseline, and meaningful savings need comparable live reviews plus inspection of their named gaps. Raising these defaults should use evidence from incomplete checks, not just a preference for fewer partial reviews.

## Validation

The full `bin/test` run passed 2,361 unit tests and 25 integration tests. Test files ran concurrently through a local Bats wrapper; each file kept its tests sequential and used separate log directories. Three additional limitations-rendering tests passed afterward. The final focused run passed 81 tests covering budget validation, exact thresholds, limited reports with no findings, chunk and retry identities, escaped Markdown, briefing generation, and retention after cleanup.

Two read-only Claude contract smoke tests returned valid reports. The normal fixture reported four tool calls, zero searches, and no gaps. The resumed fixture started at 60 calls and 12 searches, made no further investigation calls, and named the unchecked `source.py identity()` return contract. Both reports passed `reviewer-report.py --require-budget`.

A full `/review-code correctness --force` smoke attempt on a two-line fixture could not start: automatic approval review rejected the broad tool allowlist, and the restricted retry required approval for the argument-parser script. This is not an end-to-end validation result.

`bin/setup`, formatting, and changed-script Ruff and ShellCheck checks passed. All Python scripts pass with CI's pinned Ruff 0.13.0. The helper import carries an E402 exemption because bytecode generation must be disabled before importing from the installed skill tree. Local Ruff 0.16.8 accepts that ordering without an exemption, so validation uses the pinned version. Simplify, comment cleanup, and a correctness review completed with no remaining findings.

The before and after `bin/token-report --prompts --all-stages --since 2026-09-01 --json` runs both reported 1,044 dispatches. The cost report changed from 97 to 99 sessions as the local smoke sessions were recorded. Those changing aggregates do not measure a savings from the budget policy.
