## Handler: "find"

If STATUS is "find", get the find data from the session (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-find-data "<SESSION_ID>"
```

Extract these fields from the JSON output:

| Field | Default |
|-------|---------|
| `display_target` | — |
| `file_info.file_path` | — |
| `file_info.file_exists` | — |
| `file_info.has_branch_review` | false |
| `file_info.branch_review_path` | — |
| `file_info.needs_rename` | false |
| `file_info.pr_number` | — |
| `file_summary` | — |

Then cleanup the session:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

**Stop after presenting results — do not proceed with review agents.**

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

**If `has_branch_review` is true (both a PR review and a branch review exist):**

Warn the user and use AskUserQuestion:

- Question: "A branch review exists alongside the PR review. What would you like to do?"
- Options:
  1. "Merge into PR review" — Append branch review content to PR review, then delete the branch review
  2. "Keep both" — Leave both files as-is
  3. "Delete branch review" — Remove the branch review file

Show the branch review path: `$branch_review_path`

If the user selects "Merge into PR review":

1. Read both files using the Read tool
2. Append the branch review content to the PR review with separator: `\n\n---\n\n## Previous Branch Review\n\n`
3. Write the merged content to the PR review file
4. Delete the branch review file: `rm "$branch_review_path"`
5. Confirm: "Merged branch review into PR review and deleted the old file."

**If `needs_rename` is true (branch review exists, PR exists, no PR review):**

Display:

```
Found branch review for $display_target

A PR (#$pr_number) now exists for this branch.
```

Use AskUserQuestion:

- Question: "A PR (#$pr_number) now exists for this branch. Migrate the review?"
- Options:
  1. "Migrate to PR review" — Rename the file from branch to PR format
  2. "Keep as branch review" — Leave the file as-is

If the user selects "Migrate to PR review":

1. Compute the new path: replace `$file_path`'s filename with `pr-$pr_number.md`
2. Move the file: `mv "$file_path" "$new_path"`
3. Confirm: "Migrated review to $new_path"
