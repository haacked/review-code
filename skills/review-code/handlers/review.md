## Handler: "ready"

If STATUS is "ready", get the session file path (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.agents/skills/review-code/scripts/review-status-handler.sh get-session-file "<SESSION_ID>"
```

Save the output as `SESSION_FILE`. Then get the orchestrator-facing fields:

```bash
~/.agents/skills/review-code/scripts/review-status-handler.sh get-review-fields "<SESSION_ID>"
```

Save that JSON as `REVIEW_FIELDS` and show the user `display_summary`.

**Do not Read the session file itself.** It holds the review context and the full PR body and comments; those are already written to the agent briefing, and pulling them into this conversation costs their size again on every later turn. `get-review-fields` returns everything the orchestration needs and nothing it does not. Do not re-run the orchestrator.

### Handle Existing Review Files

From `REVIEW_FIELDS`, extract `file_info`: `file_exists`, `file_path`, `has_branch_review`, `branch_review_path`, `needs_rename`, and `pr_number`. The merge and migrate procedures below live in `~/.agents/skills/review-code/handlers/existing-review-files.md`; Read it when an option that uses one is selected.

**If `has_branch_review` is true** (both PR and branch reviews exist):

Use AskUserQuestion:
- Question: "A branch review exists alongside the PR review. Merge before proceeding?"
- Options:
  1. "Merge and continue": run the merge procedure, then proceed
  2. "Continue without merging": keep both files, proceed
  3. "Cancel": stop and let the user handle it manually

**If `needs_rename` is true** (branch review exists but should migrate to PR format):

Use AskUserQuestion:
- Question: "A PR (#$pr_number) exists. Migrate branch review to PR format before proceeding?"
- Options:
  1. "Migrate and continue": run the migrate procedure, update `review_file` to the new path, then proceed
  2. "Continue as branch review": keep current format, proceed
  3. "Cancel": stop and let the user handle it manually

**If `file_info.file_exists` is true** (a review file exists but neither of the above conditions apply):

First, check `REVIEW_FIELDS` for `overwrite` and `append` flags:
- If `overwrite` is true: proceed as "Overwrite" (replace the existing review) without prompting.
- If `append` is true: proceed as "Append" (add new findings to the existing review) without prompting.
- Otherwise, use AskUserQuestion to ask what to do with the existing review:
  - Options:
    1. "Overwrite": Replace the existing review
    2. "Append": Add new findings to the existing review
    3. "Cancel": Stop without reviewing

On "Cancel" in any of the prompts above: clean up the session, then stop. A worktree may have been provisioned for this session; cleanup releases it instead of leaving it behind.

```bash
~/.agents/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

### Extract Session Data

From `REVIEW_FIELDS`, extract these fields for building agent context:
- `mode`: review mode (pr, branch, commit, range, local)
- `diff_path`: filesystem path to the diff. The bytes stay on disk; agents read them.
- `artifacts_dir`: directory holding the diff and the agent briefing
- `file_metadata`: metadata about changed files
- `git`: git repository context
- `languages`: detected languages
- `file_info.file_path`: where to save the review
- `file_ref`: (optional) git ref for reading PR files when on a different branch or via a provisioned worktree
- `commit_messages_present`: boolean. The messages themselves are in `<artifacts_dir>/commit-messages.md`, not here.
- `chunk_metadata`: (optional) object with `chunked`, `reason`, `chunk_count`.
- `chunks`: (optional) array of `{id, label, files, size_kb, diff_path}`, present only when the diff was split. Each chunk's diff is on disk, so the array itself is small.
- `debug_session_dir`: (optional) path to debug session directory when debug mode is enabled
- `adversary`: (optional) object `{engine: "copilot"|"codex", available: boolean}`, present only when `--adversary:copilot` or `--adversary:codex` was specified. `available` reflects whether that engine's CLI is actually installed.

Mode-specific fields:
- **PR mode:** `pr`: identity only — `number`, `title`, `author`, `url`, `base`, `head`, `head_sha`. The body and comments are deliberately absent; they are in `briefing.md`. `head_sha` is what the re-review step below needs. `file_ref`: git ref for file access (present when reviewing from a different branch or via a provisioned worktree). When the review runs outside the PR's repo and a local clone is mapped in `repos.conf`, `git.working_dir` points at a detached worktree checked out to the PR. Otherwise (no mapping, provisioning failed, or the PR ref could not be fetched into an in-repo clone), `working_dir` is null and only the diff is available.
- **Branch/commit/range modes:** `branch`, `base_branch`, `commit`, `range`. Branch mode also carries `base_source` (how the base was chosen: `parent-flag`, `pr-base`, `stack-parent`, or `default`) and `base_lookup_degraded: "true"`, present only when the open PR's base could not be used (lookup failed, base not fetched locally, or unrelated history) and the base consequently fell back to the default branch.
- **Area-specific reviews:** `area`

### Load Conditional Instructions

Some steps apply only to certain sessions, and their instructions live in separate handler files. Check `REVIEW_FIELDS` now and Read every file whose condition holds, in one pass, before continuing:

| Condition (`REVIEW_FIELDS`) | Read this file |
|---|---|
| `debug_session_dir` is a non-empty string | `~/.agents/skills/review-code/handlers/review-debug.md` |
| `chunk_metadata.chunked` is `true` | `~/.agents/skills/review-code/handlers/review-chunked.md` |
| `adversary` is present | `~/.agents/skills/review-code/handlers/review-adversary.md` |
| `mode` is `"pr"` | `~/.agents/skills/review-code/handlers/review-pr-output.md` |
| `fix` is `true` | `~/.agents/skills/review-code/handlers/review-fix.md` |
| always, at the compose step | `~/.agents/skills/review-code/handlers/review-compose.md` (Read it then, not now) |

Each file states where in the flow below its steps run. If no condition holds, read nothing and continue.

### Decide Whether This Is a Re-review

Runs only when `append` is true in `REVIEW_FIELDS` and `file_info.file_exists` is true, meaning a review of this PR already exists on disk. Skip this section when either is false, or when `full` is true (the user asked for a complete pass with `--full`).

A re-review normally pays full freight: every agent reads the whole diff again even when the author pushed a two-line fix. The previous review's metadata header records the SHA it was taken at, so the changes since then are computable:

```bash
~/.agents/skills/review-code/scripts/review-delta.sh \
  --review-file "<file_info.file_path>" \
  --head-sha "<pr.head_sha>" \
  --base "<pr.base>" \
  --repo-dir "<git.working_dir>" \
  --out "<artifacts_dir>/delta.patch"
```

`--base` is required and the script errors without it. Deriving it would mean guessing the repository default, which is not the base of a stacked PR; the moved-base guard would then force a full review on exactly the PRs that get re-reviewed most, with a reason that reads plausible.

Read `mode` from the JSON it prints:

- **`no-change`** — head is where the last review left it. Tell the user, show them the existing review's path, and stop. Do not dispatch agents; there is nothing new to look at.
- **`delta`** — set `$review_mode` to `delta` and `$delta_from` to the returned `delta_from`. Pass the returned `diff_path` to `build-agent-briefing.sh` as `--diff-file`, along with `--previous-review "<file_info.file_path>"` so agents can see what was already raised; agents then read that diff instead of the full one. Leave the scope classifier on the full diff: classifying the smaller delta would select fewer agents, and a re-review should not be shallower than the first pass.
- **`full`** — set `$review_mode` to `full` and continue normally with the whole diff.

**Always tell the user which path this took, and for `full`, the `reason` the script gave.** A silent fallback looks identical to a delta review that found nothing, and the difference matters: a full re-review costs what it always did.

**Advance the recorded SHA.** `review_commit` in the metadata header must end up at the head this run actually reviewed. If it keeps the old value, the next re-review computes its delta from the original SHA and the saving disappears after one round. On `--append`, update the existing header rather than adding a second one.

**Carrying findings forward.** On the `delta` path the compose step loads `review-carry-forward.md`, which merges this run's sections into the existing review on disk, cuts the previous findings on files the delta touched so the agents' fresh ones stand alone, and advances the header. Never Read the previous review document: its bodies are the cost the delta path exists to avoid.

### Classify Review Scope

Run the scope classifier to determine exploration depth and agent selection based on diff size and file characteristics:

```bash
~/.agents/skills/review-code/scripts/classify-review-scope.sh "$SESSION_FILE"
```

Parse the JSON output and store:
- `$exploration_depth`: "minimal", "standard", or "thorough"
- `$selected_agents`: array of agent area names to invoke (e.g., ["correctness", "security", "testing"])
- `$skipped_agents`: array of agents that will not run
- `$classification_reasoning`: human-readable explanation

**Override rules:**
- If the user specified an `area` (e.g., `/review-code pr 123 security`), ignore the classifier output and use only that area's agent. Set `$selected_agents` to `["$area"]`, `$skipped_agents` to all other agents, `$classification_reasoning` to `"Area override: user requested area '$area'"`, and `$exploration_depth` to "standard" for area-specific reviews.
- If the classifier errors, fall back to all 7 core agents (+ frontend if applicable) and "thorough" exploration.

If agents are being skipped, briefly note this to the user:

```
Scope: $classification_reasoning
Skipping: $skipped_agents (join with ", ")
```

### Debug Mode Setup

If you loaded `review-debug.md` (`debug_session_dir` set), store `$debug_session_dir` now and write its per-stage artifacts as the flow reaches each stage.

### Track Token Usage

Track API token consumption across all agents dispatched during the review.

**Claude ($harness = `claude`):** The Agent/Task tool returns usage metadata at the end of each response:

```
<usage>total_tokens: NNN
tool_uses: NNN
duration_ms: NNN</usage>
```

Maintain a `$token_usage` map throughout the review. After each Agent/Task tool invocation completes (context explorer, review agents, chunk analyzers, finding validators), parse the `<usage>` block from its response and record `total_tokens`, `tool_uses`, and `duration_ms` keyed by agent name (e.g., `context_explorer`, `code-reviewer-security`, `chunk-1-analysis`, `validator-1`). If the usage block is absent from a response, skip that entry.

**Codex ($harness = `codex`):** Codex's JSONL stream carries different signals; the response surface is what `codex exec --output-last-message` writes. Track per-agent wall-clock (time around each `agent-dispatch.sh run` call) and any token fields in the final `turn.completed` event of the JSONL stream. Codex doesn't expose tool-call counts, so record `tool_uses` only when the JSONL provides it; otherwise omit the field. Keep the same `$token_usage` map shape so the token-report rendering downstream doesn't branch on harness.

### Prepare File Access Instructions

Build `$file_access_instructions` based on `REVIEW_FIELDS`. This block is included in both the context explorer and agent prompts. Substitute the actual `git.working_dir` path into the instructions when `working_dir` is set. Do not emit `$git.working_dir` or similar placeholders verbatim.

`git.local_clone` is set only for cross-repo reviews where a detached worktree was provisioned from a configured clone; when it is set and `working_dir` is set, `working_dir` is that worktree and Read/Grep/Glob read the PR's files directly. In the same-repo cross-branch case, `local_clone` is null and `working_dir` is the user's current checkout (which may be on a different branch), so Read on `working_dir` would read the wrong content for PR files.

**If `working_dir` is set and `file_ref` is set and `local_clone` is set:**
```
**File Access:**
A detached worktree checked out to this PR is available at the path given by `git.working_dir` in `REVIEW_FIELDS`. Use Read, Grep, and Glob normally; they operate on that directory. Do not run `git checkout` or `git switch` anywhere, and do not run other write operations in the worktree; the orchestrator owns its lifetime.
```

**If `working_dir` is set and `file_ref` is set and `local_clone` is null:**
```
**File Access:**
You are reviewing from a different branch in the same repo. The user's working tree at `git.working_dir` is on a different branch than the PR, so Read/Grep/Glob there see the wrong file contents for the PR. To read files as they appear in the PR, use `git show "$file_ref:<path>"` via the Bash tool (substitute the actual ref from `REVIEW_FIELDS` and always quote the argument to handle paths with spaces or special characters). Do NOT use `git checkout` or `git switch`: this would modify the user's working tree. Read, Grep, and Glob are still useful for finding patterns and conventions in the user's working tree, just not for reading the PR's file contents. `git show` works for any file that exists at the ref, including files newly added in the PR. If `git show` fails (e.g., the file was deleted or renamed, the path is wrong, or the ref was not fetched), fall back to the diff content.
```

**If `working_dir` is set and `file_ref` is NOT set:**
```
**File Access:**
You are on the PR's branch in the user's working directory. Use the Read tool to read files normally. Do not run `git checkout` or `git switch`: it would disturb the user's working tree.
```

**If `working_dir` is null:**
```
**File Access:**
No safe local checkout is available for reading PR files. This can happen because no local clone is configured for the repo in `repos.conf`, because worktree provisioning failed, or because the PR ref could not be fetched into the user's clone. Work primarily from the diff content, but when a finding hinges on control flow, ordering, or behavior the diff hunk doesn't show, fetch the specific file rather than concluding you can't tell (see "Verify before asking or hedging" below).
```

### Subagent Availability

The steps below spawn named subagent types: `code-review-context-explorer`, the `code-reviewer-*` reviewers, `finding-validator`, `comprehension-gate`, and `code-reviewer-voice`. How they spawn depends on the harness.

**Detect the harness once, at the start of "ready":**

```bash
~/.agents/skills/review-code/scripts/helpers/agent-dispatch.sh --detect
```

This prints `claude` or `codex`. Save it as `$harness`. If the command exits non-zero (no harness detected), stop and report the error.

**Claude ($harness = `claude`):** Spawn subagents via the Task tool with `subagent_type` set to the agent name (`code-review-context-explorer`, `code-reviewer-security`, etc.). If those names aren't registered in the environment, spawn `general-purpose` and prepend the full body of `~/.agents/agents/<subagent_type>.md` (frontmatter stripped) to the prompt; pass the definition's `model:` value if the Agent tool accepts it. Findings come back in-conversation. After `synthesis`, write each agent's raw findings to `<artifacts_dir>/findings/<agent-name>.md` (one file per reviewer) using `agent-report.sh`, so the compose step can concatenate from disk instead of holding them in context.

**Codex ($harness = `codex`):** Spawn subagents via the `codex` CLI — Codex has no Task tool or subagent registration inside the orchestrating process. For each agent in the plan:

```bash
~/.agents/skills/review-code/scripts/helpers/agent-dispatch.sh \
    run <agent-name> <prompt-file> <artifacts_dir>/findings/<agent-name>.md
```

`<prompt-file>` is a markdown file you write first containing the same prompt body the Claude path would send inline. The helper shells out to `codex exec --json --sandbox read-only --output-last-message <findings-file>`, applying the model, reasoning effort, and instructions from `~/.codex/agents/<agent-name>.toml`, so the agent's final message lands directly at the findings path. Don't repeat the agent definition in the prompt file; the helper supplies it. Codex subagents cannot stream back into this conversation; all findings, architectural context, and validation notes reach us as files.

Under Codex, dispatch is sequential unless you background the invocations; prefer backgrounding (`... &`) when the plan picks several reviewers so they run in parallel, then `wait` before synthesis. Track each backgrounded PID alongside the agent name so you can attribute a non-zero exit.

**Codex feature gaps to disclose.** Claude-only steps are:
- The coverage-resume bounce (per-agent Task resume isn't available)
- Per-agent model override (the rendered TOMLs carry the mapped model; the orchestrator cannot swap mid-flight)
- The Task tool's `<usage>` block (track wall-clock and codex's `tokens_used` from the JSONL tail instead — log what you have)

Note each gap in the review's fix/limitations section if it fired. The review still produces findings; the differences are observability and iteration depth, not coverage.

### Gather Architectural Context

Before invoking specialized agents, use the context explorer to understand the codebase.

Invoke the Task tool with subagent_type "code-review-context-explorer" and prompt below. The explorer agent runs on a cheaper model (set in its definition); review agents read the actual code behind any finding before reporting it, so the explorer does not need the top-tier model.

```markdown
Gather architectural context for this code review.

{For PR mode:}
**PR:** #$pr_number - $pr_title
**Description:** read `<artifacts_dir>/pr-body.md`.

{If pr.linked_issues is not empty:}
**Linked Issues:**
{For each issue in pr.linked_issues:}
- #$issue.number: $issue.title
{End for}

{For branch mode with associated PR:}
**Branch:** $branch vs $base_branch
**Associated PR:** #$pr_number - $pr_title
**Description:** read `<artifacts_dir>/pr-body.md`.

{For branch mode without PR:}
**Branch:** $branch vs $base_branch

{For commit mode:}
**Commit:** $commit

{For range mode:}
**Range:** $range

{For local mode:}
**Local changes** (unstaged/staged)

{For all modes:}
{If commit_messages_present:}
**Commit Messages:** read `<artifacts_dir>/commit-messages.md`.

**File Metadata:**
$file_metadata

**Diff:** read it from `$diff_path` — do not expect it inline.

$file_access_instructions

{If exploration_depth == "minimal" and "infra-config" is the only agent in $selected_agents:}
Time-box yourself to 30 seconds. This is an infrastructure config review (Helm values, K8s manifests, Terraform, ArgoCD, CI/CD).
Focus on:
- Read the modified files to understand what each configures (service, route, resource)
- Find cross-environment counterparts (dev/staging/prod variants of the same file)
- Note service and resource names referenced in the config
Do NOT search for code callers, function patterns, or application architecture.

{If exploration_depth == "minimal" (non-infra):}
Time-box yourself to 30 seconds. Focus on understanding what changed:
- Read only the modified files to understand their purpose and the change
- Skip caller search, pattern search, git history, and reference implementations

{If exploration_depth == "standard":}
Time-box yourself to 1-2 minutes. Explore:
- Full context of modified files
- Related code and dependencies
- Callers of modified functions (who calls the changed code and might be affected?)
  (grep for function/method names, report top 3-5 callers per significantly modified function)
- Skip pattern search, reference implementations, and git history

{If exploration_depth == "thorough":}
Explore the codebase to understand:
- Full context of modified files
- Related code and dependencies
- Callers of modified functions (who calls the changed code and might be affected?)
  (grep for function/method names, report top 3-5 callers per significantly modified function)
- Existing patterns for similar functionality
- Reusable utilities or conventions
- Reference implementations (if the description indicates a port, migration, or rewrite)
- Git history for high-churn files and surprising code
  (check `git_history.high_churn` flags in file_metadata; run `git log` for flagged files and for any code whose purpose is non-obvious)

Time-box yourself to 2-3 minutes of exploration.
```

Save the explorer's output as `$architectural_context`. Extract usage metadata from the response and record in `$token_usage["context_explorer"]`.

### Invoke Specialized Review Agents

Invoke the agents determined by the scope classification. If an area was specified, invoke only that agent. Otherwise, invoke all agents in `$selected_agents` in parallel (plus the frontend agent if `languages.has_frontend` is true and "frontend" is in `$selected_agents`).

**Agent selection:**

| Area | `subagent_type` | Focus |
|------|----------------|-------|
| security | code-reviewer-security | Vulnerabilities, exploits, security hardening |
| performance | code-reviewer-performance | Bottlenecks, inefficiencies, optimization |
| correctness | code-reviewer-correctness | Intent verification, integration boundaries |
| maintainability | code-reviewer-maintainability | Readability, simplicity, long-term code health |
| testing | code-reviewer-testing | Test coverage, quality, edge cases |
| compatibility | code-reviewer-compatibility | Backwards compatibility with shipped code |
| architecture | code-reviewer-architecture | Necessity, patterns, code reuse, simplicity, solution proportionality |
| infra-config | code-reviewer-infra-config | Cross-env consistency, route/service correctness, operational safety, config validation |
| *(frontend detected)* | code-reviewer-frontend | React/TS patterns, components, state, a11y |

**Build the shared briefing once, then point every agent at it.**

All agents need the same payload: PR context, commit messages, architectural context, language guidelines, and the shared review instructions. Writing it into each agent's prompt would mean retyping it once per agent and carrying it here for the rest of the run, so a script writes it to disk instead.

First save the explorer's output to a file so it can go into the briefing. Use the Write tool, with `<artifacts_dir>/architectural-context.md` as the path and the explorer's output as the content.

Do not write it with a shell heredoc. The explorer quotes code from the PR verbatim, so a file in the diff can carry a line matching the delimiter; bash ends the heredoc there and runs the rest of the explorer's output as commands. Write takes the path and the content as separate parameters, so nothing in the text can terminate it.

Then build the briefing, passing the agents being dispatched so the area-scoped diffs get written:

```bash
~/.agents/skills/review-code/scripts/build-agent-briefing.sh "$SESSION_FILE" \
  --arch-context-file "<artifacts_dir>/architectural-context.md" \
  --agents "<space-separated $selected_agents>"
```

It writes `briefing.md` and — when those agents run — `diff-frontend.patch` and `diff-infra-config.patch`, each holding only that agent's file types plus a list of the paths left out. It exits non-zero if any output is missing or empty. **If it fails, stop and report the failure. Do not dispatch agents at an unreadable briefing**: an agent that cannot read its briefing finds nothing, which looks exactly like clean code.

It prints JSON: `artifacts_dir`, `diff_path`, `briefing_lines`, `diff_lines`, and a `scoped_diffs` map of line counts. Keep those — the agent prompt needs them.

**The prompt for each agent** is then short. Substitute the agent's own diff file: `diff-frontend.patch` for frontend and `diff-infra-config.patch` for infra-config when `scoped_diffs` lists them, otherwise the `diff_path` the script returned. Use the returned `diff_path` rather than the literal `diff.patch`: on a delta re-review it points at the delta, and naming `diff.patch` there would hand every unscoped agent the whole PR while the run reports itself as incremental.

If `scoped_diffs` has no entry for a scoped agent, no file matched that agent's rule. Drop it from `$selected_agents` and add it to `$skipped_agents` so the compose step reports it as skipped. Do not dispatch it against the unscoped diff; that spends a full reviewer's tokens on files it was just filtered out of.

The line count in the prompt is that agent's own file: its `scoped_diffs` entry when it has one, otherwise `diff_lines`. Quoting the unscoped count to a scoped agent sends it paging for lines that do not exist, and an agent that receives a fraction of what it was promised may decide the briefing is broken and reply `BRIEFING_UNAVAILABLE`.

```markdown
Read `<artifacts_dir>/briefing.md` for the review context and shared instructions, then read `<artifacts_dir>/<agent-diff-file>` for the code changes. Apply your domain lens to those changes.

`briefing.md` is <briefing_lines> lines and your diff is <this agent's line count> lines. The Read tool truncates long files, so check that you received every line of both. If you got fewer, read the rest with the `offset` parameter before reviewing. Reviewing a truncated diff means silently skipping the code you did not see.

If either file is missing or unreadable, stop immediately and reply with exactly `BRIEFING_UNAVAILABLE` and nothing else. Do not review from memory or partial information.

$file_access_instructions
```

**If an agent replies `BRIEFING_UNAVAILABLE`:** Read `~/.agents/skills/review-code/handlers/review-inline-fallback.md` and re-dispatch that one agent with the payload inlined. Report in the review that the fallback fired, since it means the briefing path is broken and every later run pays full freight until it is fixed.

### Check What Each Agent Actually Read

The line counts in the agent prompt are advisory. They only help an agent that reads with the Read tool and compares; agents that page the diff with `sed` through Bash never hit a truncation to notice, and an agent that simply stops early reports nothing either. On the review of the PR that introduced this guard, three of seven agents read between 51% and 92% of their diff and none of them said so.

After the agents return, check what they read:

```bash
~/.agents/skills/review-code/scripts/check-diff-coverage.sh --diff-lines <diff_lines> --json
```

It reads this session's subagent transcripts (`--session` defaults to `$CLAUDE_CODE_SESSION_ID`) and returns per-agent coverage plus a `below_threshold` array. It exits 0 whenever it can read the transcripts; short coverage is a result, not a failure.

Each agent is sized against the patch file it actually read — the chunk or scoped diff named in its own tool calls — not against one shared count. `--diff-lines` is only the fallback for an agent whose transcript names no readable patch file, so pass the full diff's line count here even for a chunked or scoped review. Same-type agents are told apart by the `diff_path` field on each row.

For each agent in `below_threshold`, resume it (using its agent ID from the Task tool) and give it the `unread_ranges` the script reported:

```
You did not read all of `<artifacts_dir>/<agent-diff-file>`. These line ranges are still unread: <ranges>. Read them now with `sed -n '<start>,<end>p' <path>` and report any findings they contain, in the same format. Reply `NO_ADDITIONAL_FINDINGS` if there are none.
```

Merge whatever comes back into the finding pool. One re-dispatch per agent; take what you get. Record each resume's usage in `$token_usage` as `coverage-bounce-{N}`.

If the script errors (no transcripts yet, unreadable directory), say so in the review and continue. A missing coverage check is worth a line in the output; it is not worth blocking a completed review.

### Collect and Synthesize Results

After all review agents complete, extract usage metadata from each agent's response and record in `$token_usage` keyed by agent type (e.g., `$token_usage["code-reviewer-security"]`).

**Chunked review dispatch:** If you loaded `review-chunked.md` (large diff split into chunks), dispatch per its instructions instead — per-chunk analysis, then chunk x agent combinations — and merge all findings into a single pool for the synthesis below.

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
- **Corroborated (2+ agents or chunks):** Keep even if individual confidence is below 40%.
- **Solo finding, confidence >= 40%:** Include as-is.
- **Solo finding, confidence < 40%:** Drop silently.
- **Questions and nits:** Exempt from filtering. Include regardless of confidence.
- When consolidating corroborated findings, merge into a single entry using the highest confidence value. Corroboration is synthesis-time metadata used for prioritization; never embed it in the comment body (see "Comment Body Hygiene" below).

**Comment Body Hygiene:**

The `description` and `proposed_fix` text becomes the literal body of the PR review comment; keep pipeline bookkeeping out of it. No agent or model attribution ("*(corroborated by Copilot)*", "*(found by code-reviewer-security)*"), no validator verdicts ("*Downgraded from blocking: …*"), no confidence percentages or other internal scoring. Corroboration, dismissal reasoning, and confidence are synthesis-time signals: track them in your working state (or in `$debug_session_dir` artifacts when debugging), never in the body. A model name is fine when it's substantive content about the code under review ("*(the Copilot SDK rejects this header)*"); the rule targets bookkeeping, not technical claims that mention a product.

**Priority ordering in the final review:**
1. Corroborated blocking findings
2. Solo blocking findings (>= 70% confidence)
3. Corroborated suggestions
4. Solo suggestions (>= 40% confidence)
5. Questions and nits

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

### Adversary Meta-Review

If you loaded `review-adversary.md` (`--adversary:*` flag), run its meta-review pass here, between finding validation and the Voice Pass. Otherwise continue to the Comprehension Gate.

### Comprehension Gate (Cold-Reader Check)

Before the Voice Pass, check that every surviving comment body is understandable by someone reading only the comment: no diff, no code. A cheap cold-reader answers, per finding, what breaks and what the author should do; bodies it cannot follow bounce back to the agent that wrote them for a plain rewrite. This step changes body text only: it never drops findings, changes severity, or edits citations. The Voice Pass that follows stays as mechanical polish; this gate carries the register.

**Skip conditions:** If `$selected_agents` is empty (no findings will be produced) or the surviving finding pool is empty, skip this step entirely.

**Build the input.** Collect all findings that survived synthesis, validation, and the adversary meta-review. For each, include an integer `id` (sequential, starting at 1, local to this step), `severity`, `location`, `description`, `proposed_fix` (string or null), and `kind: "finding"`. Build a JSON array.

**Dispatch the check.** Invoke the Task tool with subagent_type `comprehension-gate` and a prompt that embeds the JSON array inside a **four-backtick** fence tagged `json` (finding bodies typically contain triple-backtick code blocks) and reminds the agent to answer per its definition: for each item, `what_breaks` and `action` in one sentence each, a `PASS`/`REWRITE` verdict, and `notes` naming what was unclear on every `REWRITE`, returned as a four-backtick `json` fence in the same order. Save the response. Extract usage metadata and record in `$token_usage["comprehension-gate"]`.

**Parse the output.** Extract the JSON array and match entries to input findings by `id`. An input `id` with no matching entry, an entry whose verdict is neither `PASS` nor `REWRITE`, or a malformed entry counts as `PASS` (fail open per finding). Ignore entries with unknown ids. If the returned array length differs from the input length by more than 1, treat the entire response as malformed and skip the rest of this step.

**Handle REWRITE verdicts.** For each finding the gate marked `REWRITE`:

1. Resume the agent that produced the finding (using the agent ID from the Task tool, the same mechanism as "Validate Findings Against the Diff" Step 2). If the finding has no resumable agent (for example, an adversary-added finding) or the resume errors, keep the body as-is.
2. Send it the current `description` and `proposed_fix`, the gate's `notes`, and the gate's `what_breaks`/`action` attempts, and ask for a rewrite: lead with what breaks; one idea per sentence; a teammate who has not read the diff must be able to answer "what breaks" and "what should I do" from the body alone; preserve every `path:line` citation, identifier, number, code block, and the exact severity prefix; do not add claims, citations, or fixes that are not already in the finding; a `nit:` body stays at most 2 sentences. Ask it to return only the rewritten body and the rewritten `proposed_fix` (or null).
3. Accept the rewrite only if the severity prefix is string-identical in form and every backtick-quoted path-shaped or line-number token from the original still appears (the Voice Pass preservation checks 1 and 2; no growth cap here, since the original author may legitimately restructure). If the reply is empty, malformed, or fails either check, keep the original and count the failure in `$token_usage["comprehension-gate"].validation_failures`.
4. One bounce per finding. Take what comes back; never re-gate a rewrite. Record each resume's usage in `$token_usage` as `gate-bounce-{N}` (numbered sequentially).

**Fail open, never block the review:** on an agent error or timeout, a JSON parse failure, or an array length off by more than 1, continue with the original findings. Verbose-but-correct beats blocked. This step runs in all review modes when findings exist; there is no mode-based guard.

In debug mode, save the stage `11b2-comprehension-gate` artifacts (see `review-debug.md`).

### Voice Pass (Final Rewrite)

Before composing the review document, run a single voice-pass agent over the surviving findings to rewrite their `description` and `proposed_fix` text in a clean, conversational voice. The voice agent never changes severity, citations, line numbers, identifiers, numbers, or code blocks; it changes phrasing and paragraph structure, nothing else. It may unpack a dense sentence into more, plainer sentences, up to about 2x the original length.

**Skip conditions:** If `$selected_agents` is empty (no findings will be produced) or the surviving finding pool is empty, skip this step entirely.

**Build the input.** Collect all findings that survived synthesis, validation, and the adversary meta-review, with any comprehension-gate rewrites applied (the same pool the document composer will use). For each, include an integer `id` (sequential, starting at 1), `severity` (`blocking`/`suggestion`/`question`/`nit`), `location` (file:line or file path), `description` (the comment body, including any embedded code blocks), and `proposed_fix` (string or null). Build a JSON array.

**Dispatch the rewrite.** Invoke the Task tool with subagent_type `code-reviewer-voice` and a prompt that:

1. Tells the agent to rewrite the `description` and `proposed_fix` fields in conversational voice while preserving every citation, file path, line number, identifier, number, and code block exactly. Unpacking a compressed sentence into more, plainer sentences is encouraged, up to about 2x the original length; growth never licenses new claims, citations, or fixes.
2. Tells the agent it is also responsible for paragraph structure: any body with three or more sentences must have a blank line separating the problem (what breaks and why) from the recommendation (what to do); enumerations that restate what an attached code block already shows get cut; a `nit:` body is at most two sentences. This structural responsibility does not license changing citations, code blocks, severity, or technical claims.
3. Embeds the JSON array of findings inside a **four-backtick** fence tagged `json` (because finding bodies typically contain triple-backtick code blocks; a three-backtick wrapper would close prematurely).
4. Reminds the agent to wrap its response in a four-backtick `json` fence in the same order as the input, with `id`, `description`, `proposed_fix`, and `unchanged` on each object.

Save the agent's response. Extract usage metadata and record in `$token_usage["code-reviewer-voice"]`.

**Parse the output.** Extract the JSON array from the response. For each rewritten finding, match it to the input by `id`.

- If `unchanged: true` on a rewritten finding, skip validation and keep the original `description` and `proposed_fix` for that finding (the agent is signaling no improvement was needed).
- If an input `id` has no matching rewrite, keep the original.
- If a rewritten entry has an `id` that doesn't appear in the input, ignore that entry and count it as a parse anomaly toward the validation-failure budget below.
- If the returned array length differs from the input array length by more than 1, treat the entire response as malformed and apply the agent-error fallback (continue with original findings).

**Validate preservation.** For each rewrite where `unchanged` is `false`, accept it only if all three checks hold; otherwise keep the original and count the failure in `$token_usage["code-reviewer-voice"].validation_failures`:

1. The severity prefix is string-identical in form (`` `blocking`: `` stays `` `blocking`: ``, `**blocking**:` stays `**blocking**:`).
2. Every backtick-quoted path-shaped or line-number token from the original (`auth.py:45`, `src/foo.ts`, `:67`, `line 67`) still appears. Backtick-quoted identifiers (`OverflowError`) are exempt; skip the check when the original has no such tokens.
3. The body grew to no more than about 2x the original length (unpacking dense sentences into plain ones may grow the body; paragraph breaks and punctuation tweaks never fail this on their own).

**Fail open, never block the review:** on an agent error or timeout, a JSON parse failure, or an array length off by more than 1, continue with the original findings. If more than 50% of rewrites fail validation, discard all rewrites; the voice agent is misbehaving, and verbose comments beat wrong ones.

The Voice Pass step runs in all review modes (quick and comprehensive) when findings exist. There is no mode-based guard.

In debug mode, save the stage `11c-voice-rewrite` artifacts (see `review-debug.md`).

### Link File References in Comment Bodies

If you loaded `review-pr-output.md` (PR mode), run its "Link File References in Comment Bodies" step here, right after the Voice Pass. Other modes leave references as plain `path:line` text.

### Apply Fixes (--fix flag)

If you loaded `review-fix.md` (session has `fix: true`), apply fixes per its instructions now, before composing the review document.

### Compose the Review Document

Read `~/.agents/skills/review-code/handlers/review-compose.md` and follow it to build and save the review document.

### Log Token Usage

After saving the review, append a record to the central token-usage log. Pass the raw `$token_usage` map; the script computes the sums, which is what keeps `agents_run` and `total_tokens` honest:

```bash
~/.agents/skills/review-code/scripts/log-token-usage.sh \
  --review-file "$review_file" \
  --usage '<$token_usage as a JSON object, agent key to total_tokens>' \
  --org "<org>" --repo "<repo>" --mode "<mode>" --identifier "<pr number or branch>" \
  --diff-tokens <diff_tokens> \
  --files-changed <n> --lines-added <n> --lines-removed <n> \
  --exploration-depth "<exploration_depth>" \
  --agents-skipped <n>
```

Pass `--review-mode delta --delta-from <sha>` as well when the run took the incremental path.

This covers subagent consumption only; the orchestrating conversation's own tokens are not measurable from here. Use `bin/token-report` for the full picture, including this conversation.

### PR Outputs: Suggested Comments, Draft Review, Thread Resolution

If you loaded `review-pr-output.md` (PR mode), run its remaining steps now, in order: "Generate Suggested Comments", "Create Draft Review" (--draft), and "Resolve Addressed Threads" (--append).

### Cleanup Session

After the review is complete, clean up the session (replace `<SESSION_ID>` with the actual session ID):

```bash
~/.agents/skills/review-code/scripts/review-status-handler.sh cleanup "<SESSION_ID>"
```

This removes the temporary session files and frees up disk space.
