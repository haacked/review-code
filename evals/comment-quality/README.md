# Comment quality eval

This eval measures how long and how reviewer-like the finding quality pipeline makes public review comments. It runs recorded findings through the preflight gate, composer, voice pass with its lint and repair, final gate, and one composer repair, using live `claude -p` calls.

On the prompts at `2bf4e2c`, the pipeline withheld 1 to 3 findings per run and published the rest at an average of 71 to 133 words. On the prompts at `ec61396`, every run published every finding, at an average of 44 to 66 words, in the hedged register reviewers use. The current composer aims for two sentences and about 40 words of prose, and the gate sends a body back only when it runs past two sentences or 50 words. Runs publish every finding or all but one, at an average of 33 to 48 words.

## Fixtures

The fixtures live in [`tests/fixtures/finding-comments/`](../../tests/fixtures/finding-comments/). Each case holds a finding's internal facts and fix, the domain reviewer's draft body, the body the pipeline posted (`before`), and, where one exists, the body the author approved after editing it by hand (`after`).

- [`pr-113272.json`](../../tests/fixtures/finding-comments/pr-113272.json): 12 frontend suggestions and nits from [PostHog/posthog#113272](https://github.com/PostHog/posthog/pull/113272). Its `after` bodies are the length target. `test-finding-comment-contract.bats` checks that they pass the contract's compose, gate, and publish steps unchanged.
- [`pr-121510.json`](../../tests/fixtures/finding-comments/pr-121510.json): 7 backend findings from [PostHog/posthog#121510](https://github.com/PostHog/posthog/pull/121510), one of them blocking, with no hand-edited bodies. The pipeline withheld case 3 instead of posting it, so its `before` is null.
- [`pr-118814.json`](../../tests/fixtures/finding-comments/pr-118814.json): 1 maintainability suggestion from [PostHog/posthog#118814](https://github.com/PostHog/posthog/pull/118814), with no hand-edited body, in two cases. Case 1's draft is the body the orchestrator wrote for the finding contract, not the reviewer's own draft. It opens with `"legacy" names two different hashes here.`, a word as the subject of an action verb, and later says `None of it is on master yet`, a negative subject. The pipeline posted the first sentence unchanged. That review ran before the gate's two-sentence limit, which now sends this five-sentence draft to the composer. Case 2 keeps only the first sentence and the ask, so the length limit does not hide whether the gate catches the first sentence. It was never posted, so its `before` is null.

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
gh api -H "Accept: application/vnd.github.diff" \
  repos/PostHog/posthog/compare/23b2755f062a96a825e981db42bfbec52e3fa8ff...9d99801364b1372ea361b8e16290ffff0c4231cd \
  > /tmp/pr-118814.diff
```

Then run each side at least twice. Runs share no state, so they can run in parallel:

```bash
eval=evals/scripts/run-comment-quality-eval.py
python3 $eval --diff /tmp/pr-113272.diff --out /tmp/cq/main-1 --ref main &
python3 $eval --diff /tmp/pr-113272.diff --out /tmp/cq/branch-1 &
python3 $eval --fixture tests/fixtures/finding-comments/pr-121510.json --diff /tmp/pr-121510.diff --out /tmp/cq/backend-1 &
wait
```

`--ref` reads the agent definitions, the composer's briefing, and the voice comparison rules from that commit; without it, they come from the working tree. The routing, contract, and voice lint scripts always come from the working tree, so a `--ref` run gets the working tree's lint rules. `--style detailed` runs the same findings in the detailed style. Each run writes every stage's input, reply, and verdicts to `--out`, plus `summary.json` with per-finding word counts, the commit it measured, and the CLI-reported cost. For each published body, `summary.json` and the table's Lint column also list the categories `lint-comment-voice.py` still reports, such as `action_subject` and `negative_subject`.

## Results

Two runs per side, with the voice pass in place:

| Fixture | Prompts | Published | Words per comment | Composer repairs | Cost |
| --- | --- | ---: | ---: | ---: | ---: |
| #113272 | `2bf4e2c` | 9 and 11 of 12 | 71 and 86 | 4 and 3 | $2.43 and $1.56 |
| #113272 | `ec61396` | 12 and 12 of 12 | 45 and 44 | 0 and 1 | $0.73 and $0.98 |
| #113272 | `4fb9861` | 12 and 12 of 12 | 34 and 34 | 5 and 1 | $2.18 and $1.07 |
| #113272 | `6721a15` | 12 and 11 of 12 | 35 and 33 | 1 and 1 | $0.99 and $0.83 |
| #121510 | `2bf4e2c` | 6 and 6 of 7 | 112 and 133 | 3 and 3 | $0.69 and $0.71 |
| #121510 | `ec61396` | 7 and 7 of 7 | 63 and 66 | 3 and 0 | $0.65 and $0.32 |
| #121510 | `4fb9861` | 7 and 7 of 7 | 46 and 41 | 5 and 1 | $1.04 and $0.50 |
| #121510 | `6721a15` | 7 and 7 of 7 | 47 and 48 | 3 and 0 | $0.62 and $0.34 |

Two more runs of `ec61396`, made beside the `4fb9861` runs, averaged 46 and 47 words for #113272 and 69 and 67 for #121510, so the drop comes from the two-sentence limit and not from run-to-run variation. At `4fb9861` the gate sent back any body past about 40 words. It read that as a hard limit, so every composer repair was a trim of a body of 41 to 51 words, and two of the four runs cost about twice as much as on `ec61396`. The gate at `6721a15` passes a body of up to 50 words while the composer still aims for 40. That brought repairs down to 0 to 3 per run and the average cost to $0.70, against $0.75 on `ec61396`. One `6721a15` run withheld a nit because the gate twice read its ask as contradicting the facts, the run-to-run variation that Limits describes.

The runs above read a preservation judge reply only when the reply was nothing but a JSON fence. The handler's comparison rules tell the judge to write a file, and the judge has no tool that writes one, so it often answers with a sentence before the fence. The eval then had no decision for that voice rewrite and restored the pre-voice body. In eight runs of `6721a15` on 2026-10-25, all 7 judge replies opened with such a sentence, so those runs published no voice rewrite that needed a decision. In one of them, the voice repair had rewritten case 2 of #118814, and the run still published its `"legacy" names two different hashes here.` sentence. The eval now reads the first fence in a reply and tells the judge that it has no write tool. These runs used the fixed eval:

| Fixture | Prompts | Published | Words per comment | Composer repairs | Cost |
| --- | --- | ---: | ---: | ---: | ---: |
| #113272 | `6721a15` | 12 and 12 of 12 | 34 and 35 | 1 and 0 | $1.01 and $0.74 |
| #113272 | Current | 11 and 12 of 12 | 38 and 36 | 2 and 3 | $1.46 and $1.79 |
| #121510 | `6721a15` | 7 and 7 of 7 | 46 and 45 | 2 and 1 | $0.67 and $0.50 |
| #121510 | Current | 7 and 7 of 7 | 45 and 44 | 1 and 1 | $0.47 and $0.51 |
| #118814 | `6721a15` | 2 of 2 in each of 6 runs | 35 to 45 | 5 in 6 runs | $0.18 to $0.55 |
| #118814 | Current | 2 of 2 in each of 6 runs | 40 to 48 | 2 in 6 runs | $0.18 to $0.59 |

The current prompts add the rule that a word discussed as a word, usually in quotes, can't name, decide, or want anything. On #121510 and #118814, they leave length and cost where run-to-run variation already puts them. The two #113272 runs published about 3 more words per comment than the `6721a15` runs and cost about $0.75 more. One of them withheld a finding when the recheck rejected its repaired body. Two runs can't separate that from run-to-run variation: the two `4fb9861` runs cost $2.18 and $1.07. On #118814, the current preflight gate sent case 2's two-sentence draft to the composer in all 6 runs, and it listed `"legacy" names two different hashes` among the phrases it could not resolve in 5 of them. It listed the same phrase for case 1 in 5 runs. At `6721a15`, the preflight gate passed case 2 in 2 of 6 runs, listed the phrase for case 2 in 2 runs, and never listed it for case 1. The final gate at `6721a15` then sent both passed drafts to the composer, so no published body on either side kept the sentence. No published body in these runs had a lint warning.

For comparison, the original #113272 review posted 86 words per comment, and the author's hand edits brought that to 26. The author's own inline review comments from before AI drafting have a median of 21 words and a 90th percentile of 62.

Across the four runs of `ec61396`, no comment opened an ask with "Consider" or a sentence with a negative subject such as "No test covers". They carried 6 to 11 hedges ("I think", "probably", "Mind adding…?") and 2 to 5 questions per run. The `2bf4e2c` runs had 2 to 5 "Consider" openers, 2 to 4 negative-subject sentences, and no hedges.

On `2bf4e2c`, the composer was told to open suggestions with "Consider…", and the final gate then marked those asks as unclear. Each repair repeated the pattern, so the second gate pass withheld the finding. The withheld findings included the accessibility and keyboard-focus bugs in #113272.

A detailed-style run of #113272 on `ec61396` published all 12 at 103 words each, with the mechanism and regression request in each body.

## Limits

- The gate and composer vary between runs. The same finding came out up to 22 words longer in one run than in the next, and the gate sends back different findings for repair. Compare at least two runs per side.
- In production, the orchestrator decides whether a voice rewrite kept every claim. The eval gives that decision to a separate judge call with the handler's comparison rules, which may judge differently.
- The orchestrator also checks that each composer body keeps the prefix, problem, trigger, and requested change, and withholds one that doesn't. The eval accepts every composer body that has a description, so it may publish a finding production would withhold.
- The composer sees the diff but no other source files. Production gives it the PR checkout.
- The reviewer drafts in the fixtures came from the old reviewer briefing.
- A reply whose fence opens with a space before `json` does not parse, and the eval treats it as no answer. Production's voice merge rejects that form too, and it also rejects a voice reply that closes its fence twice. Two of the 20 runs made on 2026-10-25 had one of those voice replies, and none of the 10 current runs in the second table did.
