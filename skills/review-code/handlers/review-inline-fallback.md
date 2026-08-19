# Handler: Inline Fallback Briefing

Used only when an agent replies `BRIEFING_UNAVAILABLE`, meaning it could not read the briefing files. Re-dispatch that one agent with the payload inlined.

`build-agent-briefing.sh` already ran and already validated its output as non-empty, or the run would have stopped before dispatch. So the payload exists and is correct; the agent simply could not read it. There is nothing to re-derive here.

## Re-dispatching

1. Read `<artifacts_dir>/briefing.md`.
2. Read the agent's diff file: `diff-frontend.patch` or `diff-infra-config.patch` when one exists for that agent, otherwise the `diff_path` the briefing script returned (the delta on a re-review, not necessarily `diff.patch`).
3. Re-dispatch the same `subagent_type` with both pasted inline, under the headings the agent expects:

```markdown
<contents of briefing.md>

**Code Changes:**
<contents of the agent's diff file>

$file_access_instructions
```

Nothing else changes: same agent, same domain lens, same finding format.

## Report it

Say in the review that the fallback fired and for which agent. It means the briefing path is broken, and every later run pays the full inlining cost until someone fixes it. A fallback that happens silently looks exactly like a normal review.

## Why this file does not restate the briefing

Read the real files rather than restating them here. Three copies of the same rules drift, and this copy rots first, because it only runs when something is already broken.
