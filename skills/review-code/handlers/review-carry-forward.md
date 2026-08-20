# Handler: Carry Findings Forward (Delta Re-review)

Loaded at the compose step when `$review_mode` is `delta`. Kept out of `review.md`
because it applies to re-reviews only.

**Do not Read the previous review document.** `carry-forward-findings.sh` merges
this run into it on disk. Reading it would hold the whole document (median ~12KB,
p90 ~30KB across saved reviews) in this conversation for every remaining turn, on
the run that exists to be the cheap one.

## Compose into an append file

Follow `review-compose.md` as written, with three changes:

1. Write the document to `<artifacts_dir>/review-append.md` (Write tool, new file), not to `$review_file`.
2. Open it with `# Re-review at <first 7 of pr.head_sha>` instead of the usual title, followed by one line saying what the delta covered and that findings on files it did not touch are kept above. Everything below that heading keeps the normal shape, `## Security Review` and the rest at H2, because that is what the next re-review parses.
3. Leave out the metadata header. The script moves the existing one forward: `review_commit` to this run's head, `reviewed_at`, `review_mode: delta`, and `delta_from`. The `scope` and `token_usage` blocks in that header stay as the earlier run left them; report this run's usage to the user as usual and log it with `log-token-usage.sh`.

In PR mode the Suggested Comments section goes into `review-append.md` too.
Write the file at the compose step rather than holding the composed document
across the intervening turns, and append that section to it when you reach it.
Run the merge below once the file is complete.

## Merge it in

```bash
~/.claude/skills/review-code/scripts/carry-forward-findings.sh \
  --review-file "<file_info.file_path>" \
  --delta-diff "<diff_path from review-delta.sh>" \
  --append-file "<artifacts_dir>/review-append.md" \
  --head-sha "<pr.head_sha>" \
  --delta-from "$delta_from"
```

The script cuts the previous review's findings on files the delta touched, since
the agents have just re-derived those against the new code, keeps every other
finding with its body untouched, appends what you composed, and advances the
header. It prints counts and flags only, never finding bodies, which is what
keeps this step cheap.

## Tell the user what happened

Say how many findings carried forward and how many were re-derived. Four fields
need saying out loud when they are not the happy path:

- `pruned: false` with a `prune_reason`: nothing was cut, so the document now lists the previous findings on changed files next to the new ones. Say so plainly; the user is about to read a review with duplicates in it.
- `kept_unattributed`: findings the parser could not tie to a file. They are kept deliberately. A delta review only looks at changed files, so dropping one would lose it for good rather than have an agent re-derive it.
- `kept_undeletable`: findings on changed files whose extent in the document could not be determined safely. Same reasoning, kept rather than guessed at.
- `header_updated: false`: the document had no metadata header to advance, so this run's head SHA was not recorded anywhere. The next re-review has no point to compute a delta from and falls back to a full review. Say it: the saving is gone until someone puts a header back.

Carry-forward is conservative in one direction worth a line in the review itself:
a change in one file can invalidate a finding about a file the delta never
touched, and that finding still carries forward.
