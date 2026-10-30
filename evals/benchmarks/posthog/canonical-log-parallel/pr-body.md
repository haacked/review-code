## Problem

Canonical log counters (`cohorts_evaluated`, `property_cache_hits/misses`, `flags_device_id_bucketing`, `person_properties_not_cached`, `group_properties_not_cached`) are silently lost when flag evaluation runs on the rayon thread pool.

`CANONICAL_LOG` is stored in a `tokio::task_local!`, which is only accessible from the originating tokio task. Rayon worker threads have no access to it, so all `with_canonical_log()` calls during parallel evaluation are silent no-ops. This means canonical log lines for high-flag-count requests (which trigger parallel eval) have zeroed-out evaluation counters, making them useless for debugging.

Sequential evaluation is unaffected — it runs on the tokio task where the task-local is in scope.

Closes https://github.com/PostHog/posthog/issues/47752

## Changes

**Thread-local fallback for rayon threads** (`canonical_log.rs`):
- Adds a `std::thread_local!` (`RAYON_CANONICAL_LOG`) that captures evaluation counters on rayon threads where the tokio task-local is inaccessible.
- `with_canonical_log()` now probes the tokio task-local first and falls back to the thread-local. Existing call sites are unchanged.
- `install_rayon_canonical_log()` installs a fresh `FlagsCanonicalLogLine` per flag evaluation and returns an RAII guard (`RayonCanonicalLogGuard`) that clears the thread-local on drop, ensuring cleanup even on panic.
- `take_rayon_canonical_log()` extracts the accumulated counters before the guard drops.
- `merge_rayon_delta()` merges per-flag deltas back into the request's canonical log (sums numeric counters, ORs boolean flags).

**Integration in parallel eval** (`flag_matching.rs`):
- Each rayon iteration installs a fresh thread-local, evaluates the flag, takes the delta, and sends it back alongside the result through the existing oneshot channel.
- After rayon returns, deltas are merged into the tokio task-local canonical log.

## What is NOT affected

- `flags_errored` is incremented in `process_flag_result`, which runs on the tokio task after rayon returns — it was never actually lost.
- DB query counters (`db_property_fetches`, `person_queries`, `group_queries`, etc.) run in async functions before the rayon dispatch and are unaffected.
- Flag evaluation results themselves were never affected — only observability data was lost.

