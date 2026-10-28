## Problem

- An org on `flag_evaluations_mode` 2 cannot delete its flag calls with a filtered deletion request. Deferred requests refuse. Immediate requests complete while every matching flag call stays until the TTL drops it, up to about 120 days.
- A mode 2 org writes `$feature_flag_called` only to `flag_evaluations`, so none of its flag rows has an events copy.
- #114745 deletes a flag row through the uuid of its events copy and refuses rows that have none. This PR reaches those rows.
- It has to land before new orgs default to mode 2.

## Changes

- A deferred event removal with a HogQL predicate now deletes matching flag rows that have no events copy. The queue fill reads their uuids from `sharded_flag_evaluations` with the predicate compiled against `posthog.flag_evaluations`.
- Flag rows with an events copy still go through the copy's uuid. The drain deletes a queued uuid from every table, so a flag-side match would also delete an events row the approved predicate excludes.
- The `flag_evaluations` compile refuses a predicate the two tables could answer differently:
  - one that needs a join, such as `person_id`;
  - one that reads a field the table lacks, such as `person.properties` or `elements_chain`;
  - one that events reads from a property-group map on cloud (custom keys and `$feature/` keys). The map decodes JSON escapes and compares typed values as strings. `flag_evaluations` reads raw JSON.
- A refused predicate refuses the request only when matching rows without an events copy exist, as in #114745.
- An immediate request with a predicate refuses when matching flag rows without an events copy exist, and says to file it as deferred. Rows with an events copy stay on the TTL, as before.
- Verification counts the rows without an events copy with the same compiled predicate.
- `Database.create_for` takes `include_flag_evaluations_table`, so the compile reaches the table when the org flag hides it. `translate_hogql` takes the table to resolve against and a `forbid_joins` flag.
- Mechanical: the coverage doc sections on `flag_evaluations` and HogQL predicates.

> [!NOTE]
> On cloud, events reads some `$` properties from `mat_` columns. Those read an empty string and the string "null" as NULL, and a nullable column decodes escapes. The compile does not guard these edge values; the coverage doc records them. A separate PR adds property-group maps to `flag_evaluations`, which removes the map refusal above.

## How did you test this code?

**Test rationale:**

- The deferred no-copy test, now parametrized, catches a compiled predicate that queues nothing and a refused predicate that queues rows. Its verification step catches a count that ignores the predicate.
- The events-copy test adds a row whose flag copy matches and whose events copy does not. It catches the flag predicate reaching rows with an events copy.
- The immediate test catches the immediate path skipping matching rows without an events copy.
- Routing tests materialize `$browser` on events, so an events fragment spliced into a `flag_evaluations` query fails on the missing `mat_` column.
- A parity test runs the same predicates on identical rows in both tables, including escapes, empty strings, JSON null, missing keys and typed values. It catches a HogQL change that makes the two compiles diverge for keys outside the maps.
- Compile tests cover each refusal and the case where the org flag hides the table.

Ran locally: `posthog/dags/tests/test_data_deletion_requests.py`, `posthog/models/test/test_data_deletion_request.py`, `posthog/hogql/printer/test/test_within_non_hogql_delete.py`, and repo-wide mypy. Not checked: production data, and the native-JSON events schema (`test_data_deletion_requests.py` is outside `.github/new-events-schema-targets.txt`).

## Release status

- No feature flag controls this change <!-- release-status: no-feature-flag -->

## Docs update

Internal doc only: `docs/internal/clickhouse-deletion-coverage.md`.

## 🤖 Agent context

**Autonomy:** Human-driven (agent-assisted)

**Agent:** Claude Code, Claude Opus 5.5 (`claude-opus-5-5`)

- Planned in plan mode against an approved plan, then implemented through `/go`. Skills: `/writing-tests`, `/simplify`, `/writing-pr-descriptions`.
- The approved plan applied the flag predicate to every flag row. The shipped design limits it to rows without an events copy, because the shared queue would carry a flag-side mismatch into `sharded_events`.
- A typed-property guard was replaced by the property-group map guard after a drift test showed String values diverge too. The user chose to document the `mat_` edge values rather than guard them.
- Duplicate search (`gh pr list --search "flag_evaluations deletion predicate"`) found #116553, which changes `hogql_event_removal` verification, not this path.
- All test data is invented.

https://claude.ai/code/session_012diTk9cX5pu3bA9es2HsWs
