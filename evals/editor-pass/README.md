# Combined editor evaluation

Keep the production voice pass, final comprehension gate, and overview check separate. Completed calls to a combined editor cost 14.7% less. However, it changed protected claims, approved an incomplete causal explanation, and sometimes requested an edit already present in its output. The measured saving does not justify consolidation.

## Method

The experiment ran against `3d9a4dd`, which includes the protections from [PR #178](https://github.com/haacked/review-code/pull/178). Claude Code 2.1.284 resolved `haiku` to `claude-haiku-4-5-20251001`. The baseline ran voice, final comprehension, and overview checks separately. The candidate combined those tasks in one call. Both retained independent preservation comparisons and the existing executable finding contract and publication checks.

Two- and ten-finding batches ran three times each, followed by one six-finding held-out batch. There were 16 unique findings: 12 valid and four invalid. Batch overlap and repetitions produced 34 valid and eight invalid instances, not 42 independent cases. The initial corpus included known comprehension-prompt examples; the held-out cases were absent from both prompts.

## Aggregate results

| Batch | Baseline cost | Editor cost | Reduction |
| --- | ---: | ---: | ---: |
| Small, three runs | $0.2603862 | $0.2167978 | 16.7% |
| Mixed, three completed runs | $0.3728578 | $0.3249979 | 12.8% |
| Held out | $0.1465898 | $0.1237893 | 15.6% |
| Total | $0.7798338 | $0.6655850 | 14.7% |

Each reduction uses the unrounded costs shown in its row. One editor call timed out at 240 seconds without reporting usage. Its successful retry is included above; the timed-out call's unknown cost is excluded, not counted as zero. The retry and held-out calls had a 720-second allowance. An independent cold-read audit cost $0.059647 and is excluded from both totals.

Input tokens, including cache reads/writes, fell from 225,612 to 111,819. Output tokens, including thinking, rose from 114,523 to 119,643. Summed completed-call time was 1,179.8 seconds for the baseline and 1,198.0 seconds for the editor. These are sums across concurrent experiments, not task wall time.

| Finding decisions from completed calls | Baseline | Conservative editor adapter |
| --- | ---: | ---: |
| Valid instances admitted | 33/34 | 32/34 |
| Invalid instances admitted | 0/8 | 0/8 |

The conservative adapter withheld a contradictory `unchanged: true` response. Its public body remained identical, but its proposed fix came from another finding. Restoring the original fix permits verdict reuse on the identical public body. This raises editor acceptance to 33/34, equal to baseline. The strict difference therefore reflects a protocol/adapter failure, not worse public prose in that case. This small sample does not establish a statistical quality difference.

The editor also added or reversed claims, narrowed a failure's scope, returned full coverage and `PASS` for a causal explanation that an independent cold reader rejected, and issued `REWRITE` for an edit already made. Independent preservation comparisons rejected unauthorized changes, including similar behavior from the baseline voice pass. One overview edit lost specificity and was rejected manually. Accepted findings retained full citations and code blocks.

## Synthetic regression replay

The public [fixtures](fixtures.json) are newly written fictional examples. They contain no recorded prompts, model transcripts, experiment source payloads, or account data. Their descriptions and semantic verdicts are explicit test inputs. They reproduce safeguard behavior and failure modes; they do not reproduce model behavior or recalculate the historical measurements above.

From the repository root, run:

```bash
python3 evals/scripts/replay-editor-eval.py
bats tests/unit/test-editor-eval-replay.bats
```

The offline adapter uses the current production preservation, finding-contract, and publication helpers. It rejects lost claims, shortened citations, contaminated fixes, malformed verdicts, and approval transferred from a rejected edit to a different restored body. A separate sensitivity case permits reuse only when the candidate public body is byte-identical to the restored body. Every case retains a valid neighboring finding.

The paired causal cases deliberately supply a mistaken self-approval and then an independent rejection for the same incomplete body. They demonstrate why structural checks alone cannot replace a cold reader. Likewise, a synthetic unnecessary `REWRITE` withholds an otherwise complete finding. The replay trusts supplied semantic decisions; it cannot determine prose truth or completeness itself. Overview checking and fallback are outside this finding replay.

## Limits and next experiment

Costs exclude independent preservation comparisons, composer repairs, preflight, full orchestration, source investigation, and Codex/Luna execution. Calls were not randomized for cache warmth. The timeout cost is unknown, and the overviews were clear inputs rather than a broad prose benchmark. Raw experiment material is not part of this public artifact, so these aggregate measurements cannot be independently recomputed from the synthetic fixtures.

The next experiment should batch final finding-comprehension and overview checks through the existing comprehension agent after the separate voice merge. Keep finding errors fail-closed, overview errors fail-open, distinct IDs, independent preservation decisions, semantic repair, and the final publication command. Measure complete review runs under both harnesses before changing production.
