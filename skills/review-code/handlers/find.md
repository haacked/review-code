## Handler: "find"

If STATUS is "find", get the find data from the session (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh get-find-data "<SESSION_ID>"
```

Save the JSON output. Extract the fields: `display_target`, `file_info.file_path`, `file_info.file_exists`, `file_summary`, `file_info.has_branch_review` (defaults to false), `file_info.branch_review_path`, `file_info.needs_rename` (defaults to false), `file_info.pr_number`.

Then clean up the session:

```bash
~/.claude/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

**Present the results to the user:**

If `file_exists` is "true":
- Display: "Found existing review for $display_target"
- Show the file path as a clickable link: `file://$file_path`
- Show a brief summary from `file_summary` (the first ~50 lines of the review file)
- Offer to open or read the full review

**If `has_branch_review` is "true" (both PR and branch reviews exist):**
- Display a warning: "A branch-based review also exists that can be merged"
- Show the branch review path: `$branch_review_path`
- Use AskUserQuestion to offer merge options:
  - Question: "A branch review exists alongside the PR review. What would you like to do?"
  - Options:
    1. "Merge into PR review" - Append branch review content to PR review, then delete branch review
    2. "Keep both" - Leave both files as-is
    3. "Delete branch review" - Remove the branch review file (content already in PR review)

If user selects "Merge into PR review":
1. Read both files using the Read tool
2. Append the branch review content to the PR review with a separator like `\n\n---\n\n## Previous Branch Review\n\n`
3. Write the merged content to the PR review file
4. Delete the branch review file using Bash: `rm "$branch_review_path"`
5. Confirm: "Merged branch review into PR review and deleted the old file."

**If `needs_rename` is "true" (branch review exists, PR exists but no PR review):**
- Display: "Found branch review for $display_target"
- Show that a PR (#$pr_number) now exists for this branch
- Use AskUserQuestion to offer migration:
  - Question: "A PR (#$pr_number) now exists for this branch. Migrate the review?"
  - Options:
    1. "Migrate to PR review" - Rename the file from branch to PR format
    2. "Keep as branch review" - Leave the file as-is

If user selects "Migrate to PR review":
1. Compute the new path: replace `$file_path` filename with `pr-$pr_number.md`
2. Move the file using Bash: `mv "$file_path" "$new_path"`
3. Confirm: "Migrated review to $new_path"

If `file_exists` is "false":
- Display: "No existing review found for $display_target"
- Show where the review would be saved: `$file_path`
- Suggest running `/review-code` (without `find`) to create a new review

Then stop - do not proceed with review agents.
