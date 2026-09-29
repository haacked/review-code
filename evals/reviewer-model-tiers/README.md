# Reviewer model tier evaluation

Keep all five reviewers on their current tiers. Both models found all seven keyed blocking facts. Sonnet also added false consequences, an incorrect recommendation about independent configuration, and unusable source locations. This small experiment does not establish equivalent review quality or justify the candidate branch's Codex downgrade.

## Method

The reviewer instructions come from main at `496e3eab2b3117a4b4509d2426867110b19b1869`. The candidate branch, `haacked/reviewer-model-tiers` at `03f053a72fac7e87d3363579976706a9c066f0e0`, changes compatibility, maintainability, and testing from `model: opus` to `model: sonnet`. Its unchanged `execution-tier: deep` metadata conflicts with that choice. The Codex renderer uses `model:`, so the candidate also changes those rendered Codex agents from the deep to the balanced model mapping.

Each call uses `evals/scripts/run-eval.sh --approach baseline`, with a scratch Claude CLI wrapper that selects the existing domain agent and passes `--model opus` or `--model sonnet`. The wrapper writes the request and diff to a file, removes the benchmark title and description, and uses an anonymous checkout path. Both models receive identical request bytes and source snapshots. The context file says that no architectural investigation has been performed; each reviewer performs its own searches. The allowed tools are `Bash,Read,Grep,Glob`, with delegation disabled. The model aliases resolve to `claude-opus-5-5` and `claude-sonnet-5-5`.

There is one paired run per domain. Order alternates between pairs, starting with Opus for compatibility. The testing checkout contains the pinned Rust tree; the crafted cases use a scratch service repository. Every installation and live benchmark holds the atomic `/tmp/review-code-followup-eval.lock` directory. Checkouts and raw captures remain in scratch storage. The public artifacts contain aggregate measurements and benchmark inputs, not session transcripts or account data.

This measures direct reviewer output. It omits routing, explorer-provided investigation, adversarial validation, composition, voice editing, and publication checks. It does not measure the full review pipeline or Codex models. Later stages might repair the defects observed here, at an unmeasured cost.

## Fixture preparation

The existing compatibility runner applies `base.patch` on the review branch. Under the reviewer's rules, those APIs are unshipped and cannot supply valid compatibility evidence. For this experiment, a scratch main branch contains that base plus `app.ts`, which imports and calls `createUserRouter(service)`, and `profile.ts`, which reads `UserResponse.createdAt` and `UserResponse.avatarUrl`. The copied harness omits `base.patch`; its review diff is unchanged. The service stub returns an empty list, so the pagination suggestion is not evidence of an actual returned-page regression. Compatibility recall below counts only the three source-supported blocking facts.

The testing fixture is pinned to `40f667424a3abc5691e5addeb874c4c0c33e93bf`. Both file blobs match the frozen diff. A later PR head contains corrections, so the matching source pin matters. An independent source audit also rejected the existing `missing-nonzero-base-test` expectation before either testing report was assessed. The test merges `(1, 2, 3, 1)` and then `(2, 3, 7, 4)` into the same log and asserts `(3, 5, 10, 5)`. Replacing any numeric `+=` with `=` fails that case. The corrected key treats the precise claim that this mutation escapes coverage as a false-positive trap. The remaining keyed testing finding is panic cleanup.

The new [infrastructure](../benchmarks/crafted/portal-deployment) and [frontend](../benchmarks/crafted/workspace-directory) fixtures each supply two blockers and one valid-code trap. The prior corpus had no infrastructure fixture and only one frontend nit. The infrastructure defects are a ConfigMap in the wrong namespace and an Ingress that selects a nonexistent Service port. The frontend defects are selection carried across workspaces and custom radio controls without keyboard activation.

## Finding quality

| Domain | Opus fact coverage | Sonnet fact coverage | Keyed severity |
| --- | ---: | ---: | --- |
| Compatibility | 3/3 | 3/3 | Blocking |
| Maintainability | 1/1 | 1/1 | Suggestion |
| Testing | 1/1 | 1/1 | Suggestion |
| Infrastructure | 2/2 | 2/2 | Blocking |
| Frontend | 2/2 | 2/2 | Blocking |

These are causal-fact matches, not counts of comments or strict severity matches. Opus reports the panic-cleanup gap as a nit. All ten calls completed successfully, and each pair has identical request hashes. [Measurements and assessments](measurements.json) record the per-call costs and quality checks.

The three compatibility blocker IDs cover two findings because the removed export and required parameter are reported together. Both reviewers identify the concrete TypeScript consumers. Sonnet incorrectly says renaming the `UserResponse` interface fields changes HTTP JSON; the handlers return raw service results and never call `formatUser`. Its suggested deprecation also marks the new field as deprecated in favor of itself. Both reviewers include speculative compatibility suggestions without concrete consumers.

Both maintainability reviewers identify the duplicate event functions. Sonnet recommends splitting retry policies only when their values differ, despite the documented independent endpoint tuning. Opus explicitly accepts separate policies but also incorrectly treats equal current values as contradicting independent tuning. Neither can establish that HTTP retries are absent because the transport implementation is missing. Sonnet's source anchors are generally 12 lines too high, including a range ending at line 81 in a 69-line file.

Both testing reviewers identify the panic-cleanup gap and avoid the corrected nonzero-counter trap. Both also find two issues absent from the key: missing integration coverage of parallel-log merging and a two-party barrier on a potentially single-threaded Rayon pool. These extra observations do not increase the keyed recall denominator. Sonnet gives the wrong source locations for three findings and claims stale counters leak into the next flag, although each flag installs a fresh default log. Its advice to drop the first guard explicitly would either weaken the replacement test or clear the replacement log. Opus provides more specific integration evidence, although its device-bucketing test suggestion also needs a nonempty device ID and accessible helper setup.

Both infrastructure reviewers find the namespace and Ingress defects, propose valid fixes, and accept the named target port. Sonnet places the Ingress finding at lines 96-97 in an 86-line file. Opus anchors both defects correctly. Extra questions and speculative suggestions are not counted as additional true positives.

Both frontend reviewers find the persistent selection and keyboard defects, avoid the guarded-request trap, and give valid primary fixes. Opus anchors the findings correctly. Sonnet locates the custom radio at line 69 of an 11-line file and misplaces its selection anchors. Neither reviewer tested the optional screen reader announcement suggestion.

## Costs

| Domain | Opus total | Opus requested model | Sonnet total and requested model |
| --- | ---: | ---: | ---: |
| Compatibility | $3.1651850 | $1.4861450 | $0.6761812 |
| Maintainability | $2.3270408 | $0.5677108 | $0.8811886 |
| Testing | $5.2844270 | $2.8478670 | $0.4132234 |
| Infrastructure | $2.1350310 | $0.4287810 | $0.1474322 |
| Frontend | $2.4210918 | $0.5756418 | $0.1562226 |
| Total | $15.3327756 | $5.9061456 | $2.2742480 |

Summed CLI call durations are 868.7 seconds for Opus and 99.2 seconds for Sonnet. These exclude installation, checkout preparation, lock waits, manual audits, and repository tests.

Costs are Claude Code's reported API-equivalent amounts, not incremental subscription charges. Opus results also contain separate `claude-fable-5-1` line items whose origin is not established. Reported totals and requested-model charges are kept separate. No spawned agents appear in the reviewed transcripts. Cache writes and reads differ between calls, so these amounts do not isolate model pricing. The before/after `bin/token-report` check confirms the benchmark sessions; its hard-coded prices are not substituted for the CLI's reported costs.

## Scoring limits and next comparison

The stock scorer returned zero recall for the compatibility pair because it did not parse these direct reviewer reports. Those scores are invalid. Findings were instead matched manually to causal facts and checked against the source, including false consequences, fixes, and line anchors. Independent blind audits checked compatibility, maintainability, and testing. The scorer's keyword and line-distance matching would also miss distinctions such as accepting equal configuration values versus recommending that independent policies be combined.

The baseline prompt renderer replaces ampersands with `{diff_content}` placeholders: 22 replacements in the Rust request and four in the frontend request. Both models receive the same damaged text and inspect correct source checkouts. Both frontend reports explicitly recognize the artifact. These pairs therefore measure recovery from imperfect prompts as well as review quality. Fix the renderer before repeating the comparison.

The corpus contains one case per domain, and the maintainability and testing cases have no keyed blockers. The new fixtures are small and straightforward. Calls were not randomized or repeated, cache warmth was uncontrolled, and sparse or stubbed source limits some conclusions. The public aggregates cannot reproduce the historical model outputs. A tier change needs repeated comparisons across more realistic cases, followed by complete-pipeline runs and a separate Codex comparison that measures missed blockers, false findings, repairs, and total cost.
