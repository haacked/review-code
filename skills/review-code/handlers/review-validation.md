### Validate Findings Against the Diff

Before including any finding in the final review, verify it references code actually in the diff (across all chunks if chunked). This catches wrong line numbers, findings about unrelated files, and stale references.

**Step 1: Run the position mapper.** For each agent finding that references a specific file and line, build a targets array and run:

```bash
~/.agents/skills/review-code/scripts/diff-position-mapper.sh --diff-file "<diff_path>" <<'EOF'
{"targets": [<targets array>]}
EOF
```

Where `targets` contains `{"path": "<file>", "line": <number>, "side": "LEFT"|"RIGHT"}` objects. Use `LEFT` and the old-file line number for findings on removed code, including fully deleted files. Use `RIGHT` and the new-file line number for added or surviving code. If the side is unknown, omit it; the mapper prefers `RIGHT` when both sides have that number, then falls back to `LEFT`. Resolve an ambiguous location against the cited code before mapping. The diff comes from the file, so it never passes through this conversation.

**Step 2: Handle results.** Check the `mappings` array in the output:

- **Has `side` field** (line is in the diff): Include the finding and preserve the returned `side` with its file and line through the finding contract and publication. A `LEFT` anchor is valid even when the file no longer exists in the checkout.
- **Error: `"line not in diff"`** (the requested line is absent on that side):
  1. Check the cited code's side and line number. If either is wrong, correct the target and rerun the mapper. If the code is outside the hunks, resume the agent that produced this finding (using the agent ID from the Task tool).
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

  Inspect the cited code on `$side` at `$file:$line`. For LEFT anchors, use the removed code in the diff or the base version; the checkout may have different code or no file at that path. Determine whether this finding is real or a false positive. Try to disprove it. Respond with CONFIRMED or DISMISSED and your reasoning.
  ````

  Dispatch all blocking finding validations **in parallel**. Extract usage metadata from each validator's response and record in `$token_usage` as `validator-{N}` (numbered sequentially). For each result:
  - **DISMISSED**: downgrade to `suggestion:`. If the validator's reasoning sharpens the technical content (a missing condition, a corrected line number), fold that into the body as if it were original analysis. Do not embed validator attribution like "*Downgraded from blocking: …*"; the body must stay free of pipeline metadata (see "Comment Body Hygiene").
  - **CONFIRMED**: keep as `blocking:`.
  - **Unreachable or errors**: keep the finding as-is.

- **Otherwise** (non-blocking findings): Verify the claim against the cited side before including it. Use the diff or base version for removed code and the checkout for surviving code.
