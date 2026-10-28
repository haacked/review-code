## Problem

- A flag calls insight on `posthog.flag_evaluations` cannot filter out test accounts: person, group, element and session filters fail to resolve there.
- This blocks moving orgs to the flag_evaluations-only mode, because their flag calls insights would lose the test account toggle.
- This is PR 1. A follow-up turns the toggle on for flag calls insights.

> [!WARNING]
> Merge after the 90-day re-import has run in each region and its rows carry person columns. A re-imported row without them holds `'{}'`, so a person-property test filter would let internal users through.

## Changes

- `person.properties` and `person.created_at` read the columns stored at evaluation time, as events does under persons-on-events. No persons join runs, because one does not fit in memory on the largest teams.
- `person_mode` is now a readable column, and `test_schema.py` stops hiding the three person columns from HogQL.
- Group, element and session filters resolve on the base table, not only in the events list. Element filters match nothing, as they do for a flag call on events.
- Traffic virtual properties such as `properties.$virt_is_bot` and the person `$virt_initial_*` fields resolve, so HogQL and person test account filters on them work.
- A date-bounded query reads only the groups of the flag evaluations it matched. The groups join in `groups.py` now accepts `posthog.flag_evaluations` as a prefilter source, as it does `events`.
- The groups prefilter applies only when the group join hangs off the outer `FROM` table. A group read through an explicitly joined table no longer gets its keys bounded by the outer table's rows. This changes shared code that events queries use too.
- A session filter reads only the sessions near the query's date range. The sessions join date bound in `timestamp_visitor.py` now recognizes flag_evaluations' `timestamp`.
- Restricted person properties are masked, and numeric person properties compare as numbers.
- The events list still joins `persons` for `person`, so it shows current person properties. Insights read the stored event-time values.
- Mechanical: the person subtable joins the existing person-property dispatch sites (autocomplete, catalog, property planner, type transform).

## How did you test this code?

**Test rationale:** `test_flag_evaluations.py` gains filter cases on the base table, one per test account filter type, so dropping any field breaks a case. It also asserts that `person.properties` adds no persons join, and extends the numeric and restricted-property tests to person properties. `test_restricted_properties.py` adds the new masked blob.

New tests in `test_flag_evaluations.py`:

- The groups key bound appears for both `FROM` forms the code accepts. A group filter qualified by the full `posthog.flag_evaluations` name skips the bound instead of recursing. Both failed before their fixes.
- A group read through an explicitly joined table returns that table's group. It failed before the binding fix.
- The sessions subquery carries the date bound.
- A cohort test filter resolves against the override-corrected `person_id`. This one adds coverage and guards no fix.

Ran locally: `test_flag_evaluations.py`, `test_groups_join_prefilter.py`, `test_restricted_properties.py`, `test_schema.py`, `test_events_query_runner.py`, and `posthog/hogql/database/test/`. Not checked: real prod-size queries, and any frontend surface.

## Release status

- No feature flag controls this change <!-- release-status: no-feature-flag -->

## Docs update

None.

## 🤖 Agent context

**Autonomy:** Human-driven (agent-assisted)

**Agent:** Claude Code, Opus 5.5 (claude-opus-5-5)

- The first design joined `persons` for `person.properties`. Prod measurement showed it fails on the largest teams, so the plan switched to storing person properties on the table (#114261, #116495).
- The branch was rebased onto master after its base commits merged as #114276 and #116495.
- Skills: `/go`, `/simplify`, `/comment-cleanup`, `/writing-tests`, `/writing-pr-descriptions`, `/create-pr`.
- Duplicate search found no other PR for this change.

https://claude.ai/code/session_018sD53NAazhVR2aS9tujgC6


