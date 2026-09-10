### Collect and Synthesize Results

After all review agents complete, extract usage metadata from each agent's response and record in `$token_usage` keyed by agent type (e.g., `$token_usage["code-reviewer-security"]`).

For chunked reviews, merge all completed chunk findings into a single pool. Dispatch has already completed; do not dispatch again here.

**Pre-synthesis scope filter**

After all agent results are collected (including all chunks in chunked mode), apply this filter before synthesis:

1. **Build the in-scope file list.** Let `IN_SCOPE_PATHS` be the set of file paths from `file_metadata.modified_files[].path`. These are the only files the PR is considered to touch for this filter.

2. **For each finding, check whether it is located at a specific file.** A finding has a specific file location if it names a path as the target of the issue (e.g., `src/api/views.py:42`, a section header like `#### src/api/views.py`, or an explicit `path:` field). Passing mentions of a filename inside prose (e.g., "This pattern is also used in `utils/helpers.py`") do not count.

3. **Apply the rule:**
   - Finding is located at a file **in** `IN_SCOPE_PATHS`: keep it.
   - Finding is located at a file **not in** `IN_SCOPE_PATHS`: drop it silently.
   - Finding has **no specific file location** (e.g., a general architectural observation): keep it.

This filter reduces noise before the expensive extended-thinking synthesis step. Line-level precision is handled later by the "Validate Findings Against the Diff" step.

Synthesize the remaining findings using extended thinking into a coherent, deduplicated review document. Apply confidence-based filtering and cross-agent corroboration before producing the final output.

**Cross-agent corroboration:** Two findings are corroborated if they reference the same file within 10 lines, or the same logical concern in the same function. Cross-model corroboration (an adversary meta-review `CONFIRMED` verdict, only when an adversary pass ran) also counts as corroboration even if only one Claude agent flagged the issue.

**Filtering rules:**
- **No ask (every severity, applied first):** drop any finding whose recommendation is that the author change nothing now, or whose trigger hasn't happened yet ("if a third caller is ever added"). Leaving a real change to the author's judgment ("your call") is fine; leaving them nothing to decide is not.
- **Corroborated (2+ agents or chunks):** Keep even if individual confidence is below 40%.
- **Solo finding, confidence >= 40%:** Include as-is.
- **Solo finding, confidence < 40%:** Drop silently.
- **Questions and nits:** Exempt from the confidence filter, not from the no-ask rule. Include regardless of confidence.
- When consolidating corroborated findings, merge into a single entry using the highest confidence value. Corroboration is synthesis-time metadata used for prioritization; never embed it in the comment body (see "Comment Body Hygiene" below).

**Comment Body Hygiene:**

The final `description` becomes the literal PR comment body; `proposed_fix` retains the internal fix. Keep pipeline bookkeeping out of both. No agent or model attribution ("*(corroborated by Copilot)*", "*(found by code-reviewer-security)*"), no validator verdicts ("*Downgraded from blocking: …*"), no confidence percentages or other internal scoring. Corroboration, dismissal reasoning, and confidence are synthesis-time signals: track them in your working state (or in `$debug_session_dir` artifacts when debugging), never in the body. A model name is fine when it's substantive content about the code under review ("*(the Copilot SDK rejects this header)*"); the rule targets bookkeeping, not technical claims that mention a product.

**Priority ordering in the final review:**
1. Corroborated blocking findings
2. Solo blocking findings (>= 70% confidence)
3. Corroborated suggestions
4. Solo suggestions (>= 40% confidence)
5. Questions and nits
