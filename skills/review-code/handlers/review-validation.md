### Validate Findings Against the Diff

Before including any finding in the final review, verify it references code actually in the diff (across all chunks if chunked). This catches wrong line numbers, findings about unrelated files, and stale references.

**Step 1: Run the position mapper.** For each agent finding that references a specific file and line, build a targets array and run:

```bash
~/.agents/skills/review-code/scripts/diff-position-mapper.sh --diff-file "<diff_path>" <<'EOF'
{"targets": [<targets array>]}
EOF
```

Where `targets` contains `{"path": "<file>", "line": <number>}` objects. The diff comes from the file, so it never passes through this conversation.

**Step 2: Handle results.** Check the `mappings` array in the output:

- **Has `side` field** (line is in the diff): Include the finding as-is.
- **Error: `"line not in diff"`** (file is in the diff but line is outside any hunk):
  1. Resume the agent that produced this finding (using the agent ID from the Task tool).
  2. Ask: "Your finding at `<file>:<line>` references a line outside the changed hunks in the diff. Is this finding still relevant to the changes (e.g., the issue interacts with the changed code), or should it be dropped?"
  3. Include only if the agent confirms relevance and provides justification.
- **Error: `"file not in diff"`**: Drop the finding silently. The pre-synthesis scope filter is the primary gate for this; the position mapper serves as a backstop for any that slip through.

**Step 3: Verify factual claims.** For any remaining finding that claims a bug or incorrect behavior:

- **If `blocking:`**: Invoke the Task tool with `subagent_type` "finding-validator" for each blocking finding, using this prompt:

  ````
  Validate this blocking finding from a code review.

  **Finding:**
  - **Source agent:** $agent_name
  - **Location:** $file:$line
  - **Confidence:** $confidence%
  - **Description:** $finding_description
  - **Proposed fix:**
  $proposed_fix

  **Code context from the diff:**
  ```
  $relevant_diff_snippet
  ```

  $file_access_instructions

  Read the file at `$file` (around line `$line`) and determine whether this finding is real or a false positive. Try to disprove it. Respond with CONFIRMED or DISMISSED and your reasoning.
  ````

  Dispatch all blocking finding validations **in parallel**. Extract usage metadata from each validator's response and record in `$token_usage` as `validator-{N}` (numbered sequentially). For each result:
  - **DISMISSED**: downgrade to `suggestion:`. If the validator's reasoning sharpens the technical content (a missing condition, a corrected line number), fold that into the body as if it were original analysis. Do not embed validator attribution like "*Downgraded from blocking: …*"; the body must stay free of pipeline metadata (see "Comment Body Hygiene").
  - **CONFIRMED**: keep as `blocking:`.
  - **Unreachable or errors**: keep the finding as-is.

- **Otherwise** (non-blocking findings): Use the Read tool to verify the claim is accurate before including it.
