## Existing Review File Procedures

Shared mechanics for pre-existing review files, referenced from the find handler and the review handler. Each caller asks its own AskUserQuestion; these are the procedures behind the options. The relevant session fields live under `file_info`: `file_exists`, `file_path`, `has_branch_review`, `branch_review_path`, `needs_rename`, `pr_number`.

### Merge a branch review into a PR review

Applies when `has_branch_review` is true (both a PR review and a branch review exist for the same work).

1. Read both files using the Read tool
2. Append the branch review content to the PR review with separator: `\n\n---\n\n## Previous Branch Review\n\n`
3. Write the merged content to the PR review file
4. Delete the branch review file: `rm "$branch_review_path"`
5. Confirm: "Merged branch review into PR review and deleted the old file."

### Migrate a branch review to PR format

Applies when `needs_rename` is true (a branch review exists, a PR (#$pr_number) now exists for the branch, and no PR review exists yet).

1. Compute the new path: replace `$file_path`'s filename with `pr-$pr_number.md`
2. Move the file: `mv "$file_path" "$new_path"`
3. Confirm: "Migrated review to $new_path"
