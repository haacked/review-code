## Chunked Review

Loaded when the session JSON's `chunk_metadata.chunked` is `true`: the diff was too large for one pass and was split into chunks. These instructions modify the review flow in `review.md`.

**After extracting session data**, set `is_chunked = true`, extract `chunk_count` from `chunk_metadata.chunk_count` and the `chunks` array, and display to the user:

"This is a large PR ({chunk_metadata.reason}). Splitting into {chunk_count} chunks for focused review."

**Chunked agent dispatch** (runs at the "Collect and Synthesize Results" step, replacing the single-pass dispatch):

1. **Per-chunk analysis:**

   Before dispatching review agents for chunks, run a quick analysis per chunk in parallel:

   For each chunk in the `chunks` array, invoke the Task tool with subagent_type "Explore" and `model: "sonnet"` (all chunks in parallel; chunk analysis is summarization work and does not need the top-tier model):

   ```markdown
   Analyze this chunk of a larger PR to understand its purpose and implementation details.

   **PR:** #$pr_number - $pr_title
   **Chunk:** $chunk.id of $chunk_count: $chunk.label
   **Files:** $chunk.files

   **File Metadata:**
   $file_metadata

   **Diff for this chunk:** read it from `$chunk.diff_path` — it is a file, not inline text.

   $file_access_instructions

   **Context from full-diff analysis (already gathered):**
   $architectural_context

   Build on this context. Focus on chunk-specific details not covered above.

   Provide a brief (2-3 paragraph) summary covering:
   1. What this chunk accomplishes and how it fits the PR's overall goal
   2. Chunk-specific implementation details: data flow, error handling, edge cases
   3. Integration points with other system components

   Time-box to 1-2 minutes of exploration.
   ```

   Save each chunk's analysis result as `$chunk_analyses[$chunk.id]`. Extract usage metadata from each response and record in `$token_usage` as `chunk-{id}-analysis`.

2. After all per-chunk analyses complete, for each chunk in the `chunks` array, for each applicable agent:
   - Point the agent at the chunk's `diff_path` instead of `diff.patch`; each chunk's hunks are written to their own file
   - Add a chunk context header to each agent prompt:
     ```
     **Chunk Context:**
     You are reviewing chunk $chunk.id of $chunk_count: $chunk.label
     Files in this chunk: $chunk.files (comma-separated list)
     Other chunks cover: (list labels of other chunks)
     If you notice issues that may interact with code in other chunks, flag them as questions.
     ```
   - Add the per-chunk analysis to each agent prompt:
     ```
     **Chunk Analysis:**
     $chunk_analyses[$chunk.id]
     ```
   - Everything else comes from the shared `briefing.md`, exactly as in an unchunked review; only the diff file differs per chunk
   - Dispatch all (chunk x agent) combinations in parallel via the Task tool (if the named reviewer subagent types aren't registered in this environment, apply the general-purpose fallback from review.md's "Subagent Availability" section)

3. After all tasks complete, merge all findings into a single pool for synthesis.

**Check per-chunk coverage.** Run the coverage check from `review.md` once for the whole review, not once per chunk:

```bash
~/.claude/skills/review-code/scripts/check-diff-coverage.sh --diff-lines <full diff_lines> --json
```

Do not pass a chunk's line count as `--diff-lines`: the chunk-0 agents and the chunk-1 agents read different files of different lengths, and one number cannot size both. The script sizes every agent against the patch it actually read (from its own tool calls), so a complete read of a short chunk reports as complete, a truncated read of a long chunk cannot wrap past 100%, and the two chunk instances of the same reviewer come back as separate rows named by their `diff_path`. `--diff-lines` is only the fallback for an agent whose transcript names no readable patch. Re-dispatch any `below_threshold` agent against the `unread_ranges` of its own `diff_path`.

**Notes that apply at later steps:**

- **Track Token Usage**: key each agent's usage by `chunk-{id}-{agent-type}`. In the review metadata header and the token usage log, sum tokens by agent type across chunks (e.g., all `chunk-*-code-reviewer-security` entries become a single `code-reviewer-security` total).
- **Validate Findings Against the Diff**: always pass the full diff at `diff_path` (not a chunk diff) to the position mapper's `--diff-file`. It needs the complete diff to map findings to correct GitHub inline comment positions.
- **Compose the Review Document**: the final review does NOT separate findings by chunk. Present a unified review organized by the standard priority ordering, the same as for non-chunked reviews. Add a "Review Scope" note at the top of the review document (after the metadata header):

  ```markdown
  > **Review Scope:** This review covered $chunk_count chunks ($total_file_count files total).
  ```
