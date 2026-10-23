# Comment quality eval

This eval measures how long and how reviewer-like the finding quality pipeline makes public review comments. It runs recorded findings through the preflight gate, composer, voice pass with its lint and repair, final gate, and one composer repair, using live `claude -p` calls.

On the prompts at `2bf4e2c`, the pipeline withheld 1 to 3 findings per run and published the rest at an average of 71 to 133 words. On the prompts that replaced them, every run published every finding, at an average of 44 to 66 words, in the hedged register reviewers use.

## Fixtures

Both fixtures live in [`tests/fixtures/finding-comments/`](../../tests/fixtures/finding-comments/). Each case holds a finding's internal facts and fix, the domain reviewer's draft body, the body the pipeline posted (`before`), and, where one exists, the body the author approved after editing it by hand (`after`).

- [`pr-113272.json`](../../tests/fixtures/finding-comments/pr-113272.json): 12 frontend suggestions and nits from [PostHog/posthog#113272](https://github.com/PostHog/posthog/pull/113272). Its `after` bodies are the length target. `test-finding-comment-contract.bats` checks that they pass the contract's compose, gate, and publish steps unchanged.
- [`pr-121510.json`](../../tests/fixtures/finding-comments/pr-121510.json): 7 backend findings from [PostHog/posthog#121510](https://github.com/PostHog/posthog/pull/121510), one of them blocking, with no hand-edited bodies. The pipeline withheld case 3 instead of posting it, so its `before` is null.

The approved bodies set the length target, not the voice: three of them open with "No test covers…", which the prompts now steer away from. None of the prompts' examples comes from these PRs.

## Running

Each fixture needs the diff at the commit its review read:

```bash
gh api -H "Accept: application/vnd.github.diff" \
  repos/PostHog/posthog/compare/448d802cda683dda6ec4fba42322b1a1a19875f3...35cd9393503528fb30813e3b5de37a619100c7ad \
  > /tmp/pr-113272.diff
gh api -H "Accept: application/vnd.github.diff" \
  repos/PostHog/posthog/compare/c5355d6ca0559c144ea2556b37217b70c2d958b7...c692b280bc259d04b2a94d7c2ee68167b8797d32 \
  > /tmp/pr-121510.diff
```

Then run each side at least twice. Runs share no state, so they can run in parallel:

```bash
eval=evals/scripts/run-comment-quality-eval.py
python3 $eval --diff /tmp/pr-113272.diff --out /tmp/cq/main-1 --ref main &
python3 $eval --diff /tmp/pr-113272.diff --out /tmp/cq/branch-1 &
python3 $eval --fixture tests/fixtures/finding-comments/pr-121510.json --diff /tmp/pr-121510.diff --out /tmp/cq/backend-1 &
wait
```

`--ref` reads the agent definitions, the composer's briefing, and the voice comparison rules from that commit; without it, they come from the working tree. The routing and contract scripts always come from the working tree. `--style detailed` runs the same findings in the detailed style. Each run writes every stage's input, reply, and verdicts to `--out`, plus `summary.json` with per-finding word counts, the commit it measured, and the CLI-reported cost.

## Results

Two runs per side, with the voice pass in place:

| Fixture | Prompts | Published | Words per comment | Composer repairs | Cost |
| --- | --- | ---: | ---: | ---: | ---: |
| #113272 | `2bf4e2c` | 9 and 11 of 12 | 71 and 86 | 4 and 3 | $2.43 and $1.56 |
| #113272 | This change | 12 and 12 of 12 | 45 and 44 | 0 and 1 | $0.73 and $0.98 |
| #121510 | `2bf4e2c` | 6 and 6 of 7 | 112 and 133 | 3 and 3 | $0.69 and $0.71 |
| #121510 | This change | 7 and 7 of 7 | 63 and 66 | 3 and 0 | $0.65 and $0.32 |

For comparison, the original #113272 review posted 86 words per comment, and the author's hand edits brought that to 26. The author's own inline review comments from before AI drafting have a median of 21 words and a 90th percentile of 62.

Across the four runs of this change, no comment opened an ask with "Consider" or a sentence with a negative subject such as "No test covers". They carried 6 to 11 hedges ("I think", "probably", "Mind adding…?") and 2 to 5 questions per run. The `2bf4e2c` runs had 2 to 5 "Consider" openers, 2 to 4 negative-subject sentences, and no hedges.

On `2bf4e2c`, the composer was told to open suggestions with "Consider…", and the final gate then marked those asks as unclear. Each repair repeated the pattern, so the second gate pass withheld the finding. The withheld findings included the accessibility and keyboard-focus bugs in #113272.

A detailed-style run of #113272 on this change published all 12 at 103 words each, with the mechanism and regression request in each body.

## Limits

- The gate and composer vary between runs. The same finding came out up to 22 words longer in one run than in the next, and the gate sends back different findings for repair. Compare at least two runs per side.
- In production, the orchestrator decides whether a voice rewrite kept every claim. The eval gives that decision to a separate judge call with the handler's comparison rules, which may judge differently.
- The orchestrator also checks that each composer body keeps the prefix, problem, trigger, and requested change, and withholds one that doesn't. The eval accepts every composer body that has a description, so it may publish a finding production would withhold.
- The composer sees the diff but no other source files. Production gives it the PR checkout.
- The reviewer drafts in the fixtures came from the old reviewer briefing.
