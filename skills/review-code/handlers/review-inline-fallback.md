# Handler: Inline Fallback Briefing

Used only when an agent replies `BRIEFING_UNAVAILABLE`, meaning it could not read the briefing files. Re-dispatch that one agent with the payload inlined.

`build-agent-briefing.sh` already ran and already validated its output as non-empty, or the run would have stopped before dispatch. So the payload exists and is correct; the agent simply could not read it. There is nothing to re-derive here.

## Re-dispatching

1. Read `<artifacts_dir>/briefing.md`.
2. Read the agent's diff file: `diff-frontend.patch` or `diff-infra-config.patch` when one exists for that agent, otherwise `diff.patch`.
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

An earlier version of this handler carried its own copy of the reviewer instructions, the per-mode header template, and the area-scoping rules. Three copies of the same rules drift, and the copy that rots first is this one, because it only runs when something is already broken. Pasting the real files keeps one source of truth.
