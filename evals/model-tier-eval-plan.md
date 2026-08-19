# Model-tier eval: do compatibility, maintainability, and testing survive sonnet?

This plan gates the `model:` change on branch `haacked/reviewer-model-tiers`, which moves `code-reviewer-compatibility`, `code-reviewer-maintainability`, and `code-reviewer-testing` from opus to sonnet. The change is committed but must not be installed for real reviews until the run below says findings did not regress.

Hand this file to an agent as-is. Every command is literal.

## Correction to the follow-up item that prompted this

The item said commit `59f967b` moved maintainability, testing, compatibility, infra-config, and frontend "up from fable", and that all 11 reviewers run opus. Three things are wrong.

- Those five agents were moved by **`c841863` (#113), "Cut review token spend with model tiering and search dedup"** — not `59f967b`. `59f967b` ("Switch to opus") moved the other five: architecture, correctness, performance, security, and finding-validator.
- The move was **down, not up**. Fable 5 is $10/$50 per MTok; Opus 5 is $5/$25. `#113`'s body is explicit: "move the maintainability, testing, compatibility, infra-config, and frontend agents to opus. Correctness, security, architecture, performance, and the finding-validator stay on fable." Those five were already classified as the mechanical stages and already cost-cut once. This plan cuts them a second time.
- **Ten** agents run opus, not eleven.

The item's instinct — that this set is where re-tiering belongs — survives all three corrections. `#113` reached the same conclusion from the same reasoning.

## Verified current state

| Agent | Model | Share of subagent tokens |
| --- | --- | --- |
| code-reviewer-correctness | opus | 12.4% |
| code-reviewer-security | opus | 11.3% |
| code-reviewer-maintainability | opus → **sonnet** | 10.8% |
| code-reviewer-testing | opus → **sonnet** | 10.5% |
| code-reviewer-architecture | opus | 10.2% |
| code-reviewer-compatibility | opus → **sonnet** | 9.9% |
| code-reviewer-performance | opus | 9.3% |
| code-review-context-explorer | sonnet | 9.0% |
| code-reviewer-frontend | opus | 4.0% |
| finding-validator | opus | 5.2% (all validator-N) |
| comprehension-gate | haiku | 3.1% (both gates) |
| code-reviewer-voice | haiku | 2.3% |
| code-reviewer-infra-config | opus | 0.2% |

Shares are from the 15 reviews in `~/.claude/skills/review-code/.reviews/token-usage.jsonl` that recorded per-agent usage (16.7M subagent tokens total). They are estimates from a small sample, and the column omits one-off agents (coverage-bounce resumes, an ad-hoc bash-semantics reviewer), so it does not sum to 100%.

Prices, per 1M tokens: fable-5 $10/$50, opus-5 $5/$25, sonnet-5 $3/$15 (intro $2/$10 through 2026-08-31), haiku-4.5 $1/$5. All the math below uses standard sonnet pricing, so it stays true after the intro period. Cache reads and writes scale with the same per-tier ratio, so a tier drop scales the agent's whole bill by 0.60 (opus → sonnet) regardless of the read/write/output mix.

## What is at stake

The three agents are 31.2% of subagent tokens. `bin/token-report --since 2026-08-01` over 24 review sessions puts the split at **orchestrator 59% / subagents 41%**, median $19.70 and mean $46.31 per review.

- 40% off 31.2% of subagent spend = **12.5% of subagent cost, 5.1% of total review cost**.
- ~**$2.37 on the mean review, ~$1.01 on the median**. About $57 across those 24 sessions.
- Adding frontend and infra-config would take it to 5.8% of total — 0.7 points, ~$0.33 a review.
- Dropping **all ten** opus agents to sonnet is the ceiling for this entire lever: 16.4% of total.

So the item's "largest remaining cost lever after the structural round" does not hold. The orchestrator's 59% is untouched by any `model:` frontmatter, and the whole lever caps at ~16%. This change is a real ~5%, not a step change.

One thing the estimate assumes and the run must check: that a weaker model does not burn more tokens getting to the same place. Sonnet may run more searches and more turns, eroding the 40%. See "Cost readout" below — the run measures this for free.

## Why these three, and why not the other two

The agents were judged on their prompts, then on whether the harness can gate them.

**`code-reviewer-compatibility` → sonnet.** The most mechanical reviewer in the set. Its prompt is a closed enumeration of breaking-change categories (signature changes, removed exports, changed defaults, data-format and schema changes) with before/after examples in Python, TypeScript, Rust, JSON, and SQL. The work is symbol diffing plus a caller grep the context explorer has already run. The one place discipline matters is the scope rule — never flag code added in this branch — and that is exactly what the `breaking-changes` trap tests.

**`code-reviewer-maintainability` → sonnet.** The largest single saving. Eight sections of code smells, most with numeric or lexical triggers (functions over 50 lines, cyclomatic complexity over 10, names like `data`/`temp`/`Manager`). The genuinely subjective part is the premature-abstraction call and convention calibration, and that is where a drop most plausibly costs quality: expect more cosmetic nits rather than missed findings. Precision, not recall, is the number to watch.

**`code-reviewer-testing` → sonnet, highest risk of the three.** Its checklist is mechanical, but several of its signature findings are not: mock-production fidelity (knowing `token_based=false` changes the cache key namespace), and "test claims vs actual coverage" (enumerating 12 enum variants and working out which two violate the invariant the test name promises). That is a small proof, not a pattern match. It also carries the heaviest prose-discipline load in the repo — the "Name the Failure Mode, Tersely" and "Keep 'Add a Test' Findings Short" sections — and prose discipline is the first thing to degrade on a smaller model. Score this arm with the LLM judges on, so the tier-3 readability judge sees it.

**`code-reviewer-frontend` → hold at opus.** Not because the prompt is hard — the a11y checklist and hooks rules are as mechanical as compatibility. Because **the harness cannot gate it**: the only frontend-area expected finding in any answer key is `badge-color-inconsistency` in `replay-inspector-collapse`, severity `nit`, weight 3. One nit is not evidence. It is also 4.0% of subagent tokens across n=3 reviews, skewed by a single 52-file PR. Unblock it by adding a frontend benchmark with at least one blocking finding, then re-run this plan with frontend added.

**`code-reviewer-infra-config` → hold at opus.** Also mechanical on the merits — cross-environment file comparison, grep-for-service-name, YAML field-name correctness. But **no benchmark declares an infra-config area at all**, so there is nothing to gate on, and at 0.2% of subagent tokens (n=1) there is nothing to save either. Unblock it by adding an infra-config benchmark; until then the change would be unmeasurable in both directions.

The principle: drop the tiers the harness can gate, hold the ones it cannot, and name the benchmark that would unblock each hold.

## What the harness can actually prove

`score-eval.sh` tier 1 matches a parsed finding to an expected finding on **file path + line within ±10 + at least one keyword from the answer key**. Severity is not compared. Every expected finding carries an `area`, and that area is what makes per-agent evidence possible: recall attributes cleanly per agent, because each caught/missed ID maps to exactly one area.

Coverage for the three agents under test:

| Area | Expected findings | Blocking | Benchmarks |
| --- | --- | --- | --- |
| compatibility | 4 (weight 32) | 3 | `breaking-changes` |
| maintainability | 4 (weight 20) | 0 | `canonical-log-parallel`, `group-types-cache`, `replay-inspector-collapse`, `tokio-runtime-monitoring` |
| testing | 3 (weight 18) | 0 | `canonical-log-parallel`, `s3-export-validation` |

Two consequences to hold onto.

- **"No blocking finding lost" only bites for compatibility.** Maintainability and testing have zero blocking expected findings, so their gate is recall on suggestion and nit severities — precisely the findings a weaker model is most likely to word differently enough to miss the keyword match. Treat a maintainability or testing recall drop as a real signal, not noise, because the keyword lists are generous (10-15 synonyms each).
- **Precision does not attribute per agent.** `precision.ratio` and `traps_triggered` are computed over the whole finding pool, so a noisier testing agent drags the number for everything. `clean_area_violations` does attribute, and compatibility is listed as a `clean_area` in six of the nine benchmarks — that is six independent false-positive checks on the compatibility agent, for free, on any benchmark you run.

## The run

### Prerequisites

1. **Wait for the sibling worktrees to land.** `bin/setup` writes to the shared `~/.claude/skills/review-code/` and `~/.claude/agents/`. Seven agents were working in parallel worktrees of this repo when this plan was written. Running the eval before they land will both clobber their work and measure the wrong tree.

2. **Rebase this branch onto main first.** This branch was cut from `3a3e11e`. Once the siblings land, main carries skill and handler changes this branch does not, and an un-rebased comparison measures those changes as much as the tier drop. After the rebase the branch differs from main by exactly three `model:` lines plus this file, which is not installed.

   ```bash
   cd /Users/haacked/.supacode/repos/review-code/haacked/reviewer-model-tiers
   git fetch origin && git rebase origin/main
   bin/test
   ```

3. `gh auth status` must be clean. The five PostHog benchmarks are `frozen_diff: true`, so the diff comes from the local patch, but the skill still fetches PR metadata and comments.

4. A **scratch clone** for the crafted benchmark to patch. `breaking-changes` applies a `base.patch` that creates `src/api/index.ts` and `src/api/users.ts` from `/dev/null`, on a temporary branch, and refuses to run on a dirty tree.

   ```bash
   git clone https://github.com/haacked/review-code.git /tmp/review-code-eval-target
   export EVAL_TARGET_REPO=/tmp/review-code-eval-target
   ```

5. A **checkout of main** to install the baseline tiers from. It is used only for `bin/setup`; no eval command runs there.

6. **Leave `EVAL_BUDGET_USD` unset.** `run-eval.sh`'s own comment is right: a cap that kills a run mid-review leaves a partial result that scores as a false regression.

### Where each command runs

This matters and is easy to get wrong. What the review actually does is decided entirely by what `bin/setup` last installed into `~/.claude/`. Where `run-eval.sh` runs decides only where results land.

So: **`bin/setup` alternates between checkouts; every `run-eval.sh` and `score-eval.sh` runs from this branch's worktree, for both arms.** That keeps all twelve `score.json` files and both arms' history lines in one `evals/results/` and one `evals/history/scores.jsonl`. Both directories are gitignored, so nothing lands in the commit.

The consequence: `run-eval.sh` stamps the manifest with the SHA of the checkout it runs from, so both arms carry the branch SHA and `report.sh --compare` cannot separate them. Record the six run IDs per arm instead. The gate below reads `score.json` by run ID and never needs `--compare`.

### The benchmark set

Six benchmarks, chosen as the exact union that covers every expected finding in the three target areas:

`breaking-changes`, `canonical-log-parallel`, `group-types-cache`, `replay-inspector-collapse`, `tokio-runtime-monitoring`, `s3-export-validation`

The three omitted (`shell-script-issues`, `unsafe-api`, `dual-threadpool-architecture`) carry zero expected findings in compatibility, maintainability, or testing. They would only add false-positive signal, at full review price.

### Baseline — current tiers

`evals/history/` and `evals/results/` are empty. **There is no baseline.** It has to be run, which is why the cost below is for two configs, not one.

```bash
# Install main's tiers (opus) from the main checkout.
cd ~/dev/haacked/review-code           # any checkout sitting on main
git checkout main && git pull
bin/setup

# Run from THIS branch's worktree.
cd /Users/haacked/.supacode/repos/review-code/haacked/reviewer-model-tiers
export EVAL_TARGET_REPO=/tmp/review-code-eval-target
wc -l ~/.claude/skills/review-code/.reviews/token-usage.jsonl   # note this number

for b in breaking-changes canonical-log-parallel group-types-cache \
         replay-inspector-collapse tokio-runtime-monitoring s3-export-validation; do
  evals/scripts/run-eval.sh --benchmark "$b" --approach skill
done
```

Each invocation prints its own run ID (`YYYYMMDD-HHMMSS-<sha>`) and writes to `evals/results/<run-id>/`. **Record all six as the baseline arm.** Score each:

```bash
evals/scripts/score-eval.sh <run-id>
```

Run the scorer **with** the LLM judges. They cost at most $0.50 each and there are two per benchmark, so under $1 per benchmark against a review that costs $20-60 — roughly 2% of the run. The tier-3 readability judge is the only instrument that measures prose degradation, which is the specific risk for the testing agent. Use `--no-llm` only if judge spend somehow matters; note that it zeroes the LLM term and drags `composite_score` by its 0.30 weight, so a `--no-llm` composite is comparable only to another `--no-llm` composite.

### Treatment — three agents on sonnet

```bash
# Install the branch's tiers (sonnet for the three).
cd /Users/haacked/.supacode/repos/review-code/haacked/reviewer-model-tiers
bin/setup

# Run from the same worktree, so both arms' results share one directory.
export EVAL_TARGET_REPO=/tmp/review-code-eval-target
wc -l ~/.claude/skills/review-code/.reviews/token-usage.jsonl   # note this number

for b in breaking-changes canonical-log-parallel group-types-cache \
         replay-inspector-collapse tokio-runtime-monitoring s3-export-validation; do
  evals/scripts/run-eval.sh --benchmark "$b" --approach skill
done
```

Record the six run IDs as the treatment arm and score them the same way.

### Restore

Whichever config wins, `bin/setup` from that checkout before doing any real review. The installed copy is what every `/review-code` run uses.

## The gate

Compare per benchmark, baseline run ID against treatment run ID, from `evals/results/<run-id>/<benchmark>/score.json`.

**Landing conditions — all four must hold.**

1. **No blocking expected finding is lost.** Cross-reference `recall.findings_caught` against the answer key's `severity` field. On this benchmark set the blocking findings in a target area are the three in `breaking-changes` (`renamed-export`, `removed-response-fields`, `added-required-parameter`). Any one of them caught on baseline and missed on the branch is a revert, not a tradeoff. Blocking findings in non-target areas (correctness, security, performance) should be unchanged; if they move, something other than the tier drop is at work and the run is not clean.

   ```bash
   jq -r '.recall.findings_caught[], "--", .recall.findings_missed[]' \
     evals/results/<run-id>/breaking-changes/score.json
   ```

2. **Weighted recall does not fall by more than 0.05 on any benchmark.** `recall.weighted` is pool-wide per benchmark, so read it alongside the caught/missed IDs to see which area moved. A drop concentrated in the target areas is the signal; a drop in correctness or security is run noise or a broken run.

3. **No new false-positive trap fires, and `clean_area_violations` does not increase.** The compatibility trap is `additive-delete-endpoint` in `breaking-changes` — a purely additive DELETE endpoint that a careless reviewer calls breaking. Compatibility is a declared clean area in `shell-script-issues`, `unsafe-api`, `dual-threadpool-architecture`, `group-types-cache`, `replay-inspector-collapse`, `s3-export-validation`, and `tokio-runtime-monitoring`; four of those are in this set.

4. **Readability mean does not fall by more than 0.5.** `readability.mean` from the tier-3 judge, which cold-reads every finding body with no diff and no code. This is the gate on the testing agent's prose discipline. A drop here with recall intact still means revert testing: the point of that agent's prompt is comment quality as much as coverage.

**Per-agent verdict.** Each of the three can be reverted independently. Map missed IDs to areas:

- compatibility fails → revert `agents/code-reviewer-compatibility.md` to `model: opus`
- maintainability fails (any of `fragile-field-by-field-merge`, `missing-exception-context-in-cache-helpers`, `redundant-onclick-handler`, `duplicated-loop-structure`) → revert maintainability
- testing fails (any of `missing-nonzero-base-test`, `panic-safety-untested`, `missing-host-vs-url-test-coverage`) → revert testing

**Noise floor.** Reviews are model-driven and will not be bit-identical. This plan deliberately does not budget a second baseline pass up front, because that would add ~$210 to catch variance that may not appear. Instead: when a benchmark looks like it regressed, **re-run that one benchmark on both configs** before reverting. Re-running one benchmark costs $20-60; a blanket noise-floor pass costs an entire config. If you would rather have the floor up front, run the baseline loop twice and treat the spread between the two baseline runs as the threshold in condition 2 instead of 0.05.

## Cost readout — free, and the point of the exercise

Both arms append per-agent records to `~/.claude/skills/review-code/.reviews/token-usage.jsonl`. With the line counts noted before each loop, slice the two arms and compare the three agents' `total_tokens` directly:

```bash
tail -n +<baseline-start-line> ~/.claude/skills/review-code/.reviews/token-usage.jsonl \
  | jq -s '[.[] | .agents | {c:.["code-reviewer-compatibility"],
                             m:.["code-reviewer-maintainability"],
                             t:.["code-reviewer-testing"]}]'
```

If sonnet's token counts come back materially higher than opus's for the same benchmark, the 40% price cut is partly eaten by extra searching and the real saving is below the 5.1% estimated above. That number should go into the landing decision alongside the quality gate.

## What it costs to run

Estimates, from `bin/token-report --since 2026-08-01` (24 sessions, median $19.70, mean $46.31, total $1,111.52). Five of the six benchmarks are real PostHog PRs at `hard` difficulty, which sit above the median; `breaking-changes` is a small crafted TypeScript diff and sits well below it.

| Option | Reviews | Estimate | Covers |
| --- | --- | --- | --- |
| **Recommended** — 6 benchmarks × 2 configs | 12 | **~$400** (range $250-700) | compatibility 4/4, maintainability 4/4, testing 3/3 |
| Minimum viable — `breaking-changes`, `group-types-cache`, `canonical-log-parallel` × 2 | 6 | ~$190 (range $130-250) | compatibility 4/4, maintainability 2/4, testing 2/3 |
| With noise floor — baseline run twice | 18 | ~$610 (range $380-1050) | as recommended, plus a measured variance threshold |
| Everything — all 9 benchmarks × 2 configs | 18 | ~$560 (range $350-1000) | adds only non-target-area signal |

Scoring adds under $1 per benchmark scored (two LLM judges, each capped at $0.50), so at most $12 on the recommended option. `--no-llm` makes it free and gives up condition 4.

The recommended option costs roughly **170 mean reviews' worth of the saving** it is validating ($400 ÷ $2.37). It pays back over a few months at current review volume, and it is a one-time cost that also establishes the baseline this repo does not have — every later tiering question gets cheaper because of it.

## If it lands

- `bin/setup` from this branch.
- Add a follow-up to build a frontend benchmark with a blocking finding and an infra-config benchmark, since those are the two holds and both are blocked on coverage rather than judgment.
- The next tiering question to ask is not another reviewer. It is the orchestrator's 59%, which no `model:` frontmatter can reach.
