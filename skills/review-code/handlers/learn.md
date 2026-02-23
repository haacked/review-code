## Handler: "learn"

The learn mode analyzes PR review outcomes to improve future reviews. It uses the learn orchestrator to coordinate workflow.

### Initialize Learn Mode

From the `PARSE_RESULT` (saved earlier), extract `learn_submode` and `pr_number`.

Run the orchestrator based on submode:

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

Save the JSON output as `LEARN_RESULT`. Extract the `status` field.

If status is "error", extract the `error` field, display it to the user, and stop.

Based on `learn_submode`, proceed to the appropriate handler:

### Learn Submode: "single"

Analyze a specific PR's outcomes.

**Step 1: Display cross-reference summary**

From `LEARN_RESULT`, extract the `summary` object and display it:

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

Also extract `learn_data` from `LEARN_RESULT` for subsequent steps.

**Step 3: Process prompts for uncertain items**

For each item in `prompts_needed`, ask the user interactively:

**For "unaddressed" findings (Claude found, not modified):**

Use AskUserQuestion:
- Question: "Claude flagged this issue, but the file wasn't modified. What happened?"
- Display the finding details: file, line, description, agent, confidence
- Options:
  1. "False positive" - Claude was wrong, this doesn't need fixing
  2. "Correct but deferred" - Valid issue, but postponed for later
  3. "Correct but low priority" - Valid but not worth changing
  4. "Skip" - Don't record this learning

**For "missed" findings (other reviewer found, Claude missed):**

Use AskUserQuestion:
- Question: "Another reviewer found this issue that Claude missed. Should Claude learn to detect this?"
- Display the finding details: file, line, description, author
- Options:
  1. "Yes, add to patterns" - Claude should catch this in future reviews
  2. "No, too specific" - This was a one-off case
  3. "Skip" - Don't record this learning

**Step 4: Record learnings**

For each user response (except "Skip"), create a learning record:

```json
{
  "timestamp": "2026-02-02T10:30:00Z",
  "pr_number": 123,
  "org": "from learn_data",
  "repo": "from learn_data",
  "type": "false_positive | missed_pattern | valid_catch | deferred",
  "source": "claude | other_reviewer",
  "agent": "from finding",
  "finding": {
    "file": "from finding",
    "line": "from finding",
    "description": "from finding"
  },
  "context": {
    "language": "detect from file extension",
    "framework": "if known"
  },
  "user_feedback": "user's selection reason if any"
}
```

Append each learning JSON record to `~/.claude/skills/review-code/learnings/index.jsonl` using the Write tool (append mode) or the Edit tool.

**Step 5: Mark PR as analyzed**

Read `~/.claude/skills/review-code/learnings/analyzed.json` using the Read tool (create `{}` if it doesn't exist). Extract `org` and `repo` from `learn_data`. Add an entry: `{"<org>/<repo>": {"<pr_number>": "<timestamp>"}}` merged into the existing data. Write the updated JSON back using the Write tool.

**Step 6: Display completion**

```
Learning complete for PR #123

Learnings recorded:
- 2 false positives
- 1 missed pattern added

Run '/review-code learn --apply' when ready to update context files.
```

### Learn Submode: "batch"

Analyze all unanalyzed PRs with existing reviews.

**Step 1: Check orchestrator result**

From `LEARN_RESULT` (saved from initialization), extract `count` and `prs`.

**Step 2: Check if any PRs to analyze**

If COUNT is 0:
```
No unanalyzed PRs found with existing reviews.

To create reviews for analysis:
1. Run '/review-code <pr-number>' on PRs
2. Wait for PRs to be merged
3. Run '/review-code learn' to analyze outcomes
```

**Step 3: Process each PR**

For each PR in the batch, run the single analysis by calling the orchestrator:

```bash
~/.claude/skills/review-code/scripts/learn-orchestrator.sh single "<PR_NUM>" --org "<ORG>" --repo "<REPO>"
```

For each PR, follow the "single" submode flow (user prompts for uncertain items).

After each PR, ask if the user wants to continue:

Use AskUserQuestion:
- Question: "Continue to next PR?"
- Options:
  1. "Yes, analyze next PR"
  2. "Stop here"

If user selects "Stop here", exit the batch loop.

**Step 4: Display batch summary**

```
Batch Analysis Complete

PRs analyzed: 3/5
Learnings recorded: 7 total
- 3 false positives
- 2 deferred issues
- 2 missed patterns

Run '/review-code learn --apply' to update context files.
```

### Learn Submode: "apply"

Synthesize accumulated learnings into context file updates.

**Step 1: Check orchestrator result**

From `LEARN_RESULT` (saved from initialization), extract `actionable` and `proposals`.

**Step 2: Check if any proposals**

If ACTIONABLE is 0:
```
No patterns ready for context updates.

Requirements:
- At least 3 occurrences of the same pattern type
- Learnings must share language/framework context

Current learnings: X total
Grouped patterns: Y
Patterns meeting threshold: 0

Continue collecting learnings with '/review-code learn <pr>'
```

**Step 3: Present each proposal**

For each proposal in `proposals`:

Display the proposal:
```
Proposed Context Update

**Target file:** context/languages/python.md
**Section:** ## Python Patterns
**Based on:** 4 learnings

**Proposed content:**
```
<proposed content from script>
```

This pattern was identified from PRs: #123, #456, #789, #101
```

Use AskUserQuestion:
- Question: "Apply this update to the context file?"
- Options:
  1. "Apply" - Add this content to the context file
  2. "Edit first" - Let me modify the content before applying
  3. "Skip" - Don't add this pattern
  4. "Stop" - Stop processing proposals

**If "Apply":**

1. Check if target file exists
2. If not, create it with a header
3. Append the proposed content
4. Confirm: "Added to context/languages/python.md"

**If "Edit first":**

1. Display the proposed content in a code block
2. Ask user to provide edited version
3. Apply the edited version

**If "Skip":**

Continue to next proposal.

**If "Stop":**

Exit the apply loop.

**Step 4: Clear applied learnings (optional)**

After applying proposals, ask:

Use AskUserQuestion:
- Question: "Clear the learnings that were applied?"
- Options:
  1. "Yes, clear applied" - Remove learnings that were used in applied proposals
  2. "No, keep all" - Keep learnings for future reference

If "Yes", filter out the applied learnings from index.jsonl.

**Step 5: Display apply summary**

```
Context Updates Applied

Files updated:
- context/languages/python.md (2 patterns)
- context/frameworks/django.md (1 pattern)

These improvements will be used in future reviews.
```
