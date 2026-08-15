## Handler: "learn"

The learn mode analyzes PR review outcomes to improve future reviews.

### Initialize Learn Mode

From `PARSE_RESULT`, extract `learn_submode` and `pr_number`. Run the orchestrator:

- **If submode is "single":**
  ```bash
  ~/.claude/skills/review-code/scripts/learn-orchestrator.sh single "<PR_NUMBER>"
  ```
- **If submode is "batch":**
  ```bash
  ~/.claude/skills/review-code/scripts/learn-orchestrator.sh batch
  ```
- **If submode is "apply":**
  ```bash
  ~/.claude/skills/review-code/scripts/learn-orchestrator.sh apply
  ```

Save the JSON output as `LEARN_RESULT`. If the `status` field is "error", display the `error` field and stop.

Proceed to the submode handler below.

---

### Learn Submode: "single"

Extract `summary` and `learn_data` from `LEARN_RESULT`.

**1. Show the cross-reference summary.** From `summary`, report for PR #`pr_number`: how many of Claude's findings were likely addressed in subsequent commits vs. not modified vs. unclear (`claude_addressed`, `claude_not_addressed`, `claude_total`), how many findings from other reviewers Claude also caught vs. missed (`other_caught_by_claude`, `other_missed_by_claude`, `other_total`), and how many items need the user's judgment (`prompts_count`).

**2. Process prompts for uncertain items.** For each item in `prompts_needed`:

For **"unaddressed" findings** (Claude found, file not modified after review), show file, line, description, agent, and confidence, then use AskUserQuestion:
- Question: "Claude flagged this issue, but the file wasn't modified. What happened?"
- Options:
  1. "False positive": Claude was wrong, no fix needed
  2. "Correct but deferred": Valid issue, postponed
  3. "Correct but low priority": Valid but not worth changing
  4. "Skip": Don't record this learning

For **"missed" findings** (other reviewer found, Claude missed), show file, line, description, and author, then use AskUserQuestion:
- Question: "Another reviewer found this issue that Claude missed. Should Claude learn to detect this?"
- Options:
  1. "Yes, add to patterns": Claude should catch this in future reviews
  2. "No, too specific": One-off case, not worth generalizing
  3. "Skip": Don't record this learning

**3. Record learnings.** For each response other than "Skip", append a record to `~/.claude/skills/review-code/.learnings/index.jsonl`:

```json
{
  "timestamp": "<current ISO 8601 timestamp>",
  "pr_number": "<from learn_data>",
  "org": "<from learn_data>",
  "repo": "<from learn_data>",
  "type": "false_positive | missed_pattern | valid_catch | deferred",
  "source": "claude | other_reviewer",
  "agent": "<from finding>",
  "finding": {
    "file": "<from finding>",
    "line": "<from finding>",
    "description": "<from finding>"
  },
  "context": {
    "language": "<detected from file extension>",
    "framework": "<if known>"
  },
  "user_feedback": "<user's selection>"
}
```

**4. Mark the PR as analyzed.** Read `~/.claude/skills/review-code/.learnings/analyzed.json` (create `{}` if missing). Extract `org` and `repo` from `learn_data`. Merge `{"<org>/<repo>": {"<pr_number>": "<timestamp>"}}` into the existing data and write it back.

**5. Wrap up.** Report the counts of learnings recorded by type, and point at `/review-code learn --apply` for updating context files once patterns accumulate.

---

### Learn Submode: "batch"

From `LEARN_RESULT`, extract `count` and `prs`.

If `count` is 0, tell the user there are no unanalyzed PRs with existing reviews (reviews come from running `/review-code <pr>`; outcome analysis makes sense once those PRs are merged) and stop.

For each PR in the batch, run:

```bash
~/.claude/skills/review-code/scripts/learn-orchestrator.sh single "<PR_NUM>" --org "<ORG>" --repo "<REPO>"
```

Follow the "single" submode flow for each PR (user prompts, record learnings, mark analyzed). After each PR, use AskUserQuestion to ask whether to continue to the next PR or stop; exit the loop on "Stop here".

When done, report PRs analyzed out of the total and the counts of learnings recorded by type, and point at `/review-code learn --apply`.

---

### Learn Submode: "apply"

From `LEARN_RESULT`, extract `actionable` and `proposals`.

If `actionable` is 0, explain why nothing is ready: applying requires at least 3 occurrences of the same pattern type sharing language/framework context. Report the current totals from `LEARN_RESULT` (learnings collected, grouped patterns) and suggest continuing to collect with `/review-code learn <pr>`. Stop.

**Present each proposal.** For each proposal in `proposals`, show the target file (`proposal.target_file`), the section, how many learnings it's based on, the proposed content, and the PRs it was identified from. Then use AskUserQuestion:
- Options:
  1. "Apply": Add content to the context file
  2. "Edit first": Modify content before applying
  3. "Skip": Skip this proposal
  4. "Stop": Exit without processing remaining proposals

**If "Apply":** Check if the target file exists (create with a header if not), append the proposed content, and confirm: "Added to `<target_file>`".

**If "Edit first":** Display the proposed content, ask the user for the edited version, then apply it.

**If "Skip":** Continue to the next proposal.

**If "Stop":** Exit the loop.

**Offer to clear applied learnings.** Use AskUserQuestion:
- Question: "Clear the learnings that were applied?"
- Options:
  1. "Yes, clear applied": Remove learnings used in applied proposals from index.jsonl
  2. "No, keep all": Keep all learnings for future reference

Finish by listing the context files updated and the number of patterns each received.
