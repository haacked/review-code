# Kea Framework Guidelines

## State Management & Kea Logic

Use React state for local component state: form inputs, UI toggles, self-contained primitive components, state no other component needs. Use Kea for state shared across components, complex async workflows with side effects, and global application state. A Kea logic wrapping what could be a `useState` is over-engineering; shared state threaded through props that unrelated components need is the opposite miss.

Kea issues to catch:

- Direct state mutations in reducers (reducers must return new objects/arrays)
- Missing error handling in async listeners (listeners without try/catch)
- Missing cleanup in `afterUnmount`

## Kea Logic Keys

The `key()` function must produce stable, predictable keys. Unstable keys break component identity and cause remounting; keys built from object references change on every render; `JSON.stringify` crashes on circular references and produces long keys.

```typescript
// Fragile: crashes on circular refs, non-deterministic, or reference-based
key((props) => JSON.stringify(props.value))
key((props) => props.complexObject)

// Stable: primitives or predictable string combinations
key((props) => props.id)
key((props) => `${props.type}-${props.id}`)
```

For array or nullable props, serialize predictably (e.g. `value.map((v) => v ?? 'null').join('-')`).

## Props Synchronization

Add `propsChanged` when a logic receives props that can change externally (a `value` controlled by the parent, config that affects internal state). Without it, the logic's state silently diverges from the parent after the first render and the UI shows stale data.

```typescript
propsChanged(({ actions, props }, oldProps) => {
    if (props.value !== oldProps.value) {
        actions.updateInternalState(props.value)
    }
    // For complex values, compare with deep equality before reloading
}),
```
