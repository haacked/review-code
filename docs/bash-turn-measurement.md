# Bash-turn measurement

The review handlers use completion notifications or native blocking waits, and the metadata writer generates its own UTC timestamp. Codex batches launch and wait for every child inside one script. The contract tests verify these paths without paid model calls.

## Transcript evidence

The September 1, 2026 followup recorded 2.7 pure glue Bash calls per session across 196 sessions, with 34 total Bash calls per session. Its examples were `true` (1.07/session), `sleep 1` (0.52), `date -u +%Y-%m-%dT%H:%M:%SZ` (0.35), and `echo "waiting for background agents"` (0.15). The baseline combined `bin/token-report --match review-code-review-` with raw transcript analysis.

Measured again on September 28, before installing this change, using the retained Claude transcripts:

```bash
bin/token-report --match review-code-review- --bash-glue --json --limit 0
bin/token-report --match review-code-review- --since 2026-09-01 --bash-glue --json --limit 0
```

| Sample | Sessions | Bash calls | Known glue calls | Glue calls/session |
| --- | ---: | ---: | ---: | ---: |
| September 1 baseline | 196 | about 34/session | about 2.7/session | 2.7 |
| Retained transcripts on September 28 | 155 | 10,022 | 1,381 | 8.910 |
| Retained sessions started since September 1 | 61 | 5,961 | 981 | 16.082 |

| Known glue form | All retained sessions | Sessions started since September 1 |
| --- | ---: | ---: |
| `true` or `:` | 740 | 531 |
| Standalone `sleep` with a numeric duration | 109 | 0 |
| UTC ISO timestamp via `date` | 55 | 16 |
| `echo waiting`, including waiting for agents | 477 | 434 |

The samples differ, so these figures do not establish a trend against the original 196 sessions. They show that throwaway calls remain in the available review transcripts. These sessions also span different installed skill versions; they cannot all be attributed to the current source revision.

The new report uses the cost report's project, start-date, and minimum-three-turn session filters. It counts only top-level assistant Bash tool calls, deduplicated by tool-use ID. It excludes subagent transcripts and includes sessions with zero glue calls in the denominator. The command's whole trimmed body must be under 40 characters. Compound commands and unknown short commands do not count as known glue. `short_non_skill_calls` is reported separately and includes useful work such as `git status`; it is not a savings estimate. No transcript text or identifiers are needed for the aggregate report above.

## Before and after the implementation

The source baseline is `3208b07`. These are executable contract results, not a measured post-deployment average:

| Contract | Before | After |
| --- | --- | --- |
| Full-review metadata | Compose generates `reviewed_at` with shell `date`; writer rejects an omitted timestamp | Compose passes no timestamp; writer records UTC for full and delta updates, preserving explicit overrides |
| Claude completion | Dispatch instructions leave waiting unspecified | Every stage uses completion notifications, or blocking TaskOutput/native wait when notifications are unavailable |
| Codex parallel completion | Handler asks the orchestrator to background commands and track PIDs | One batch command launches children and waits for every exit in the same shell |
| Failed child | Orchestrator must attribute a nonzero exit itself | Batch returns failure after all children finish and identifies the failing agent and output path |
| No-op Bash calls | No explicit prohibition | Shared dispatch contract forbids `true`, `:`, `sleep`, and `echo waiting` as orchestration turns |

The metadata change removes a `date` expression from the compose command. That expression was already embedded in the command, so the source change alone does not prove one fewer tool call on every review. It removes the need for the separate timestamp calls observed in transcripts. Delta carry-forward, token logging, and debug timing already generate their timestamps in scripts and retain that behavior.

The tests execute the documented compose and Codex batch commands. The batch stub forces both agents to start before either can finish, then finishes them out of order. Early and late failures must both return failure, and the caller must observe every sibling's completion before the batch returns. Invalid manifests cannot start any agent. Existing single-agent dispatch, explicit timestamps, metadata reads, and the cost and prompt reports remain covered.

```bash
bats tests/unit/test-agent-dispatch.bats tests/unit/test-handler-contracts.bats tests/unit/test-update-review-metadata.bats tests/unit/test-bash-glue-report.bats tests/unit/test-token-report.bats
```

These controlled paths require zero pure glue Bash calls. No live Claude or Codex review was run to establish a new average. Re-run the transcript report after reviews use the new installation, with `--since` set to its rollout date. Do not infer dollar savings by multiplying calls by the old $0.70 estimate. A tool call need not occupy its own model turn, and context size and pricing differ across runs.
