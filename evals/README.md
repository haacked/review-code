# Evals

Benchmarks and scoring for `/review-code`. A benchmark is a diff with an answer key; a run sends that diff through the skill and scores what came back against the key.

```
evals/
    benchmarks/
        crafted/       Hand-built diffs with a base.patch to apply
        posthog/       Real PostHog PRs, most with frozen_diff: true
        registry.json  Benchmark list, categories, declared areas
    prompts/baseline.md
    scripts/
        run-eval.sh    Run benchmarks, write evals/results/<run-id>/
        score-eval.sh  Score a run, append to evals/history/scores.jsonl
        report.sh      Tabulate scores.jsonl
    results/           Gitignored
    history/           Gitignored
```

## Running and scoring

```bash
evals/scripts/run-eval.sh --benchmark <id> --approach skill
evals/scripts/score-eval.sh <run-id>
evals/scripts/report.sh --last 10
```

`run-eval.sh` also takes `--all`, `--category <cat>`, and `--sample`. `--benchmark` is single-valued, so a named subset means one invocation per benchmark and one run ID each.

Two environment variables matter:

- `EVAL_TARGET_REPO` — the checkout that crafted-benchmark patches get applied in. Point it at a scratch clone; the patches create branches and refuse to run on a dirty tree.
- `EVAL_BUDGET_USD` — leave it unset. A run killed mid-review by a cap produces a partial result that scores as a regression that never happened.

`gh auth status` should be clean before a run. Frozen-diff benchmarks take the diff from the local patch, but the skill still fetches PR metadata and comments.

## Where each command runs

Easy to get wrong, and expensive when you do. **What a review actually does is decided entirely by what `bin/setup` last installed into `~/.claude/`.** Where `run-eval.sh` runs decides only where results land.

Two consequences:

- `bin/setup` writes to the shared `~/.claude/skills/review-code/` and `~/.claude/agents/`. A sibling worktree running `bin/setup` mid-eval clobbers the tree you are measuring. Check for parallel work before starting.
- Running every command from one checkout keeps all `score.json` files and history lines in one `evals/results/` and one `evals/history/scores.jsonl`, which is what you want when comparing runs.

## What the scoring can prove

`score-eval.sh` runs three tiers: pattern matching against the answer key, an LLM judge on finding quality, and a cold-reader readability judge that sees finding bodies with no diff and no code.

Tier 1 matches a parsed finding to an expected finding on **file path + line within ±10 + at least one keyword from the answer key** (`check_finding_match` in `scripts/helpers/eval-helpers.sh`). Severity is not compared.

Every expected finding carries an `area`, and that is what makes per-agent evidence possible:

- **Recall attributes per agent.** Each caught or missed ID maps to exactly one area, so a recall change points at a specific reviewer.
- **Precision does not.** `precision.ratio` and `traps_triggered` are computed over the whole finding pool, so one noisy agent drags the number for everything.
- **`clean_area_violations` does attribute.** An answer key's `clean_areas` list declares areas that should produce no findings at all, which is a free false-positive check on those agents for any benchmark you run.

Note the nesting when reading `score.json` directly: the tier-1 block sits under `.pattern_matching` (`.pattern_matching.recall.weighted`, `.pattern_matching.recall.findings_missed`), while `.readability` is top level.

`--no-llm` skips tiers 2 and 3. It zeroes the LLM term and drags `composite_score` by its 0.30 weight, so a `--no-llm` composite is comparable only to another `--no-llm` composite.

## A/B-ing two configurations

To test whether a change to the agents or the skill helps, run both configurations over the same benchmark set and compare per benchmark.

The trap: `run-eval.sh` stamps the manifest with the git SHA of the checkout it runs from. Two arms run from one checkout carry the same SHA, so `report.sh --compare <sha1> <sha2>`, which partitions history by SHA, cannot separate them. `report.sh --last N` and `report.sh --benchmark <id>` are unaffected and cover recall and readability directly; anything else goes to `score.json` by run ID.

So capture each arm's run IDs as you go rather than reconstructing them later:

```bash
BENCHES="benchmark-a benchmark-b benchmark-c"   # the set both arms run

run_arm() {                                  # $1 = arm name
  bin/setup                                  # installs whatever the tree says right now
  date -u +%FT%TZ > "/tmp/arm-$1.start"
  for b in ${BENCHES}; do
    evals/scripts/run-eval.sh --benchmark "$b" --approach skill
  done
  date -u +%FT%TZ > "/tmp/arm-$1.end"
  find evals/results -mindepth 1 -maxdepth 1 -type d -newer "/tmp/arm-$1.start" \
    -exec basename {} \; | sort > "/tmp/arm-$1.runs"
  for r in $(cat "/tmp/arm-$1.runs"); do evals/scripts/score-eval.sh "$r"; done
}
```

Benchmarks have to run serially: run IDs are second-granularity, the PostHog benchmarks serialize on a single per-repo review worktree, and crafted benchmarks refuse a dirty `EVAL_TARGET_REPO`. Nothing above pipes `run-eval.sh`'s output, so the review it drives keeps its terminal.

The start and end markers also bracket each arm's records in `~/.claude/skills/review-code/.reviews/token-usage.jsonl`, whose entries carry a `reviewed_at` timestamp. That gives a per-agent token comparison between arms for free — worth reading when the change was meant to save money, since a weaker model can burn the saving back in extra searching.

## Adding a benchmark

Add a directory under `benchmarks/crafted/` or `benchmarks/posthog/` with `metadata.json`, `diff.patch`, and `answer-key.json` (plus `base.patch` for crafted diffs that need files to exist first), then register it in `registry.json`.

An area is only gateable if some answer key declares expected findings in it, and only a `blocking` expected finding supports a "no blocking finding lost" gate. Areas with no expected findings anywhere — or a single `nit` — cannot produce evidence in either direction. Keep `registry.json`'s `areas` in sync with the keys' `expected_findings[].area`; they are allowed to drift and nothing checks them.
