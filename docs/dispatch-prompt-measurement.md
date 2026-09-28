# Review dispatch prompts, September 28, 2026

Large finding batches still enter comprehension, voice, and composition prompts inline. The normal domain-review path already passes artifact references. The quality handler now uses `build-finding-prompt.py` for every call and repair. It validates the input artifact and rejects dispatch prompts of 4096 UTF-8 bytes or more without truncating findings.

## Measurement

The starting revision was `3208b07`. Running `bin/token-report --prompts` against the local Claude transcript corpus reported 1,462 dispatches: 284 inlined, 957 by reference, and 221 with no recognized payload. Adding `--since 2026-09-01` produced identical results because prompt mode ignored that flag. The classifier also missed JSON input paths and finding arrays, and the default agent filter omitted comprehension gates.

The updated command filters each dispatch by its first timestamp, includes the other review stages, and recognizes inline finding arrays before considering file references:

```bash
bin/token-report --prompts --all-stages --since 2026-09-01 --json
bin/token-report --prompts --all-stages --since 2026-09-01 --limit 10
```

The default `--match review` corpus contains 1,031 matching dispatches since September 1:

| Stage | Dispatches | Median tokens | p90 tokens | Maximum tokens |
| --- | ---: | ---: | ---: | ---: |
| Domain review | 495 | 288 | 407 | 822 |
| Context exploration | 80 | 676 | 1,033 | 1,331 |
| Finding validation | 38 | 834 | 1,358 | 1,524 |
| Composition | 71 | 677 | 1,184 | 2,498 |
| Voice | 75 | 329 | 772 | 3,767 |
| Comprehension | 272 | 331 | 566 | 4,851 |

The September 1 cost note used the narrower project filter `--match review-code-review-`. Adding that filter to the dated command leaves 870 dispatches, including 411 domain reviews with a 288-token median, 441-token p90, and 822-token maximum. The wider table above includes additional review worktrees and should not be compared directly with the old 196-session cost aggregate.

The classifier detects inline finding arrays in 95 comprehension, 28 voice, and 26 composition prompts. The largest composition batch uses `current_description`, which is also recognized. Each JSON row includes the timestamp, stage, and transcript path so a large result can be inspected rather than inferred from its aggregate category.

Token counts estimate characters divided by four. These are first user prompts, not the agent definition, tool reads, total billed tokens, or resumed calls. Shape classification is heuristic: an incidental path can count as a reference, and unrecognized prose can still contain payload. The report reads Claude transcripts for the named review agents; generic fallback agents, built-in `Explore` chunk analyzers, and Codex subprocess dispatches are outside this corpus. The current chunk handler supplies analysis and diff artifact paths, but this table does not measure those built-in analyzer prompts.

## Historical prompts and intentional inline cases

All 284 domain-review prompts containing a diff predate September 1. The most recent is August 15. The current domain path has 494 file-reference prompts and one short request without a recognized payload. Those historical large prompts do not establish a current domain-dispatch regression.

`review-inline-fallback.md` intentionally pastes the briefing and diff after a reviewer returns `BRIEFING_UNAVAILABLE`. That fallback remains available and must be disclosed in the review. No recent domain prompt in this corpus contains an inline diff. The named-agent fallback also includes the agent definition when its type is unavailable; the new size bound applies before that harness-specific addition. Finding validators intentionally receive one finding and its relevant diff snippet. Their recent maximum was 1,524 estimated tokens, so this change leaves that path alone.

## Before and after

For each quality prompt above 2,400 estimated tokens, the first inline finding array was extracted unchanged into a JSON file. The new builder generated a prompt against that file. Composer context used nonempty placeholder artifacts because the archived session artifacts were unavailable; only their paths enter the generated prompt.

| Original dispatch (UTC) | Stage | Items | Before tokens | Generated tokens |
| --- | --- | ---: | ---: | ---: |
| September 22, 17:59 | Comprehension | 14 | 4,851 | 147 |
| September 8, 17:35 | Comprehension | 8 | 4,630 | 146 |
| September 8, 17:40 | Voice | 8 | 3,767 | 146 |
| September 8, 17:43 | Comprehension | 8 | 3,452 | 146 |
| September 9, 21:44 | Comprehension | 6 | 3,179 | 146 |
| September 8, 18:50 | Voice | 8 | 2,820 | 146 |
| September 22, 18:02 | Composition | 3 | 2,498 | 242 |

The seven generated prompts total 1,119 estimated tokens versus 25,197 in the transcripts, a 95.6% reduction in dispatch text. This is a replay of prompt construction, not a measured reduction in total review cost. Agents still read the complete finding payload, and artifact path lengths affect the generated size.

Running `bin/token-report --prompts --all-stages` on minimal replay transcripts classified all seven original prompts as inlined and all seven generated prompts as by reference. Their median dispatch size changed from 3,452 to 146 estimated tokens.

## Regression coverage

`test-build-finding-prompt.bats` checks a 350-finding batch, payload isolation, complete-read instructions, composer-only source access, missing and malformed inputs, empty batches, and the UTF-8 prompt limit. `test-handler-contracts.bats` executes the documented dispatch command for all three agents and checks that missing input stops execution before dispatch. `test-token-report.bats` covers date boundaries, undated records, stage selection, JSON paths, inline finding arrays, and transcript attribution.

The final focused run passed all 51 tests, and the integration suite passed all 25. The full unit run passed 2,260 cases and failed 20 because their log directories were outside the filesystem sandbox. All 40 tests in those two meta-review suites passed after setting writable `CODEX_LOG_DIR` and `COPILOT_LOG_DIR` paths. A later classifier regression was included in the final focused run, covering 2,281 unit cases across the runs. Formatting and changed-file lint passed. The 40 repository-wide lint findings reproduce unchanged on the base revision.

`bin/setup` completed. A read-only Claude comprehension agent consumed a generated file-reference prompt, returned the fixture's id, and produced verdicts accepted by the gate parser. The longer `/review-code` smoke test was stopped when a concurrent install replaced the shared handler, so it does not establish an end-to-end result for this branch.
