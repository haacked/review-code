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

Analyze a specific PR's outcomes.

**Step 1: Display cross-reference summary**

Extract `summary` from `LEARN_RESULT` and display:

```
Cross-Reference Summary for PR #<summary.pr_number>

Claude's Findings (<summary.claude_total> total):
- <summary.claude_addressed> likely addressed in subsequent commits
- <summary.claude_not_addressed> not modified after review
- <remaining> unclear

Other Reviewers Found (<summary.other_total> total):
- <summary.other_caught_by_claude> also caught by Claude
- <summary.other_missed_by_claude> Claude missed

Prompts needed: <summary.prompts_count>
```

Also extract `learn_data` from `LEARN_RESULT` for use in later steps.

**Step 2: Process prompts for uncertain items**

**Quick mode (when invoked from post-review prompt):**

If this learn flow was triggered from the post-review learning opportunity (not from a direct `/review-code learn` invocation), use auto-categorization instead of interactive prompts:

- Unaddressed findings with confidence < 85% → record as "low priority" (type: "deferred", user_feedback: "auto: low priority")
- Unaddressed findings with confidence >= 85% → record as "deferred" (type: "deferred", user_feedback: "auto: high confidence deferred")
- Missed findings where the file was modified after review → record as "add to patterns" (type: "missed_pattern", user_feedback: "auto: file was modified")
- All other missed findings → skip

Display a summary table instead of individual prompts:
```
Auto-categorized N findings:
- X low priority (confidence < 85%)
- Y deferred (confidence >= 85%)
- Z patterns to learn from

Use '/review-code learn <pr>' for interactive categorization.
```

Then proceed to Step 3 to record learnings and Step 4 to mark as analyzed.

**Interactive mode (default):**

For each item in `prompts_needed`, ask the user:

For **"unaddressed" findings** (Claude found, file not modified after review):

Use AskUserQuestion:
- Question: "Claude flagged this issue, but the file wasn't modified. What happened?"
- Display finding details: file, line, description, agent, confidence
- Options:
  1. "False positive" — Claude was wrong, no fix needed
  2. "Correct but deferred" — Valid issue, postponed
  3. "Correct but low priority" — Valid but not worth changing
  4. "Skip" — Don't record this learning

For **"missed" findings** (other reviewer found, Claude missed):

Use AskUserQuestion:
- Question: "Another reviewer found this issue that Claude missed. Should Claude learn to detect this?"
- Display finding details: file, line, description, author
- Options:
  1. "Yes, add to patterns" — Claude should catch this in future reviews
  2. "No, too specific" — One-off case, not worth generalizing
  3. "Skip" — Don't record this learning

**Step 3: Record learnings**

For each response other than "Skip", append a record to `~/.claude/skills/review-code/learnings/index.jsonl`:

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

**Step 4: Mark PR as analyzed**

Read `~/.claude/skills/review-code/learnings/analyzed.json` (create `{}` if missing). Extract `org` and `repo` from `learn_data`. Merge `{"<org>/<repo>": {"<pr_number>": "<timestamp>"}}` into the existing data and write it back.

**Step 5: Display completion**

```
Learning complete for PR #<pr_number>

Learnings recorded:
- <N> false positives
- <N> missed patterns added

Run '/review-code learn --apply' when ready to update context files.
```

---

### Learn Submode: "batch"

Analyze all unanalyzed PRs with existing reviews.

**Step 1: Extract batch data**

From `LEARN_RESULT`, extract `count` and `prs`.

**Step 2: Handle empty batch**

If `count` is 0:

```
No unanalyzed PRs found with existing reviews.

To create reviews for analysis:
1. Run '/review-code <pr-number>' on PRs
2. Wait for PRs to be merged
3. Run '/review-code learn' to analyze outcomes
```

Stop here.

**Step 3: Process each PR**

For each PR in the batch, run:

```bash
~/.claude/skills/review-code/scripts/learn-orchestrator.sh single "<PR_NUM>" --org "<ORG>" --repo "<REPO>"
```

Follow the "single" submode flow for each PR (user prompts, record learnings, mark analyzed).

After each PR, ask:

Use AskUserQuestion:
- Question: "Continue to next PR?"
- Options:
  1. "Yes, analyze next PR"
  2. "Stop here"

Exit the batch loop if the user selects "Stop here".

**Step 4: Display batch summary**

```
Batch Analysis Complete

PRs analyzed: <analyzed>/<total>
Learnings recorded: <N> total
- <N> false positives
- <N> deferred issues
- <N> missed patterns

Run '/review-code learn --apply' to update context files.
```

---

### Learn Submode: "apply"

Synthesize accumulated learnings into context file updates.

**Step 1: Extract proposals**

From `LEARN_RESULT`, extract `actionable` and `proposals`.

**Step 2: Handle no proposals**

If `actionable` is 0:

```
No patterns ready for context updates.

Requirements:
- At least 3 occurrences of the same pattern type
- Learnings must share language/framework context

Current learnings: <N> total
Grouped patterns: <N>
Patterns meeting threshold: 0

Continue collecting learnings with '/review-code learn <pr>'
```

Stop here.

**Step 3: Present each proposal**

For each proposal in `proposals`, display:

```
Proposed Context Update

Target file: <proposal.target_file>
Section: <proposal.section>
Based on: <N> learnings

Proposed content:
<proposed content from proposal>

Identified from PRs: <pr list>
```

Use AskUserQuestion:
- Options:
  1. "Apply" — Add content to the context file
  2. "Edit first" — Modify content before applying
  3. "Skip" — Skip this proposal
  4. "Stop" — Exit without processing remaining proposals

**If "Apply":** Check if the target file exists (create with a header if not), append the proposed content, and confirm: "Added to `<target_file>`".

**If "Edit first":** Display the proposed content, ask the user for the edited version, then apply it.

**If "Skip":** Continue to the next proposal.

**If "Stop":** Exit the loop.

**Step 4: Offer to clear applied learnings**

Use AskUserQuestion:
- Question: "Clear the learnings that were applied?"
- Options:
  1. "Yes, clear applied" — Remove learnings used in applied proposals from index.jsonl
  2. "No, keep all" — Keep all learnings for future reference

**Step 5: Display apply summary**

```
Context Updates Applied

Files updated:
- <file> (<N> patterns)
- <file> (<N> patterns)

These improvements will be used in future reviews.
```
