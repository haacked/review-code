## Amend a Pending Review

Loaded on request, when a comment on a review you already posted needs rewording or removing. Nothing here runs as part of a review; a review that has just been posted is already correct as far as it knows.

Use this when the author pushes back and they are right, when a finding turns out to be partly wrong, or when re-reading the posted comment shows the wording lands badly. Do not re-run the review to fix a comment: `--draft` only posts at the end of a review, so a re-run costs every agent again, gives every comment a new id, and discards anything edited by hand in the GitHub UI.

**Never use a raw `gh api` call for this.** The PreToolUse hook blocks the review-comment endpoints on both REST and GraphQL, and the reason it blocks them is that they can delete a published comment, including someone else's. `amend-pending-review.sh` refuses any comment that is not in your own pending review.

### The four steps

Work in this order. Step 1 exists because the author may have edited a comment in the GitHub UI, and skipping it means overwriting their edit.

**1. See where things stand.**

```bash
~/.agents/skills/review-code/scripts/amend-pending-review.sh <pr> --json
```

Each recorded comment comes back as one of:

| State | Meaning |
|---|---|
| `in_sync` | The notes and GitHub agree |
| `changed_on_github` | Someone edited the comment in the UI; the notes are stale |
| `changed_in_notes` | You reworded it in the notes and have not pushed yet |
| `diverged` | Both moved; the UI edit and your reword conflict |
| `missing_on_github` | The comment is gone, but the finding is still live in the notes |
| `unknown_baseline` | Posted before ids were recorded, so neither side can be trusted as the baseline |

**2. Pull anything GitHub changed.**

```bash
~/.agents/skills/review-code/scripts/amend-pending-review.sh <pr> --pull
```

This copies GitHub's wording into the notes. Run it whenever anything reads `changed_on_github`, `diverged`, or `unknown_baseline`. `--push` refuses while any comment is in one of the first two states, and tells you so.

**3. Reword in the review file.** Edit the ` ```text ` body of the finding block. Change only the body: the heading, its `<!-- pc:… -->` annotation, and the `*From: …*` line are how the two sides stay matched.

Keep the voice rules that applied when the comment was written (see Inline Comment Voice in `review.md`), including the blank line at the seam between problem and recommendation.

**4. Push it back.**

```bash
# Check first. This prints the full body of everything it would change.
~/.agents/skills/review-code/scripts/amend-pending-review.sh <pr> --push --dry-run
~/.agents/skills/review-code/scripts/amend-pending-review.sh <pr> --push
```

Add `--comment-id <id>` to push one comment when you reworded several and only want one to go.

The comment keeps its id, so any reply thread on it survives, and the review stays `PENDING` throughout.

### Dropping a finding outright

When the finding is wrong rather than badly worded, take the comment off the PR and record why:

```bash
~/.agents/skills/review-code/scripts/amend-pending-review.sh <pr> \
  --drop --comment-id <id> --reason "author showed environments are deprecated; confirmed in prod"
```

Deletion is irreversible and the body is not recoverable from GitHub afterwards, so run it with `--dry-run` first and read the body it echoes.

This marks the finding withdrawn in the review file rather than deleting it. The block stays, so the argument that retired it stays on the record, and a later `--append` re-review will neither carry it forward nor repost it. Write a real reason: it is what a reader, and the learning pass, use to tell a false positive from a fix that landed.

### What this cannot do

- **A finding in the review body.** Comments that could not be mapped to a diff position are folded into the pending review's summary under `**Additional Notes:**` and have no comment id. Change those in the GitHub UI.
- **A pending review this tooling did not post.** Without recorded ids there is nothing to match on. The status output says so rather than guessing.
- **A submitted review.** Once submitted, its comments are public and out of scope here.

If a step fails, stop and report it. Do not fall back to a raw API call, and do not submit the review: submitting is never the way to fix a wrong comment.
