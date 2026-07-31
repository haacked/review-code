## Handler: "find"

If STATUS is "find", get the find data from the session (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-find-data "<SESSION_ID>"
```

Extract these fields from the JSON output:

| Field | Default |
|-------|---------|
| `display_target` | always set |
| `file_info.file_path` | always set |
| `file_info.file_exists` | false |
| `file_info.has_branch_review` | false |
| `file_info.branch_review_path` | null |
| `file_info.needs_rename` | false |
| `file_info.pr_number` | null |
| `file_summary` | "" |

Then cleanup the session:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

**Stop after presenting results. Do not proceed with review agents.**

---

### If `file_exists` is false

Display:

```
No existing review found for $display_target

Review would be saved to: $file_path

Run `/review-code` (without `find`) to create a new review.
```

---

### If `file_exists` is true

Display:

```
Found existing review for $display_target

file://$file_path
```

Show a brief summary from `file_summary` (the first ~50 lines of the review file) and offer to open or read the full review.

The merge and migrate procedures below live in `~/.claude/skills/review-code/handlers/existing-review-files.md`; Read it when an option that uses one is selected.

**If `has_branch_review` is true (both a PR review and a branch review exist):**

Warn the user, show the branch review path (`$branch_review_path`), and use AskUserQuestion:

- Question: "A branch review exists alongside the PR review. What would you like to do?"
- Options:
  1. "Merge into PR review": run the merge procedure
  2. "Keep both": leave both files as-is
  3. "Delete branch review": `rm "$branch_review_path"`

**If `needs_rename` is true (branch review exists, PR exists, no PR review):**

Display:

```
Found branch review for $display_target

A PR (#$pr_number) now exists for this branch.
```

Use AskUserQuestion:

- Question: "A PR (#$pr_number) now exists for this branch. Migrate the review?"
- Options:
  1. "Migrate to PR review": run the migrate procedure
  2. "Keep as branch review": leave the file as-is
