# Kea Framework Guidelines

## State Management & Kea Logic

**Kea Over-Engineering** - Use React state for:

- Local component state (form inputs, UI toggles)
- Simple controlled inputs
- Self-contained primitive components
- State that no other component needs

**Use Kea for:**

- State shared across multiple components
- Complex async workflows with side effects
- Global application state
- State accessed by unrelated components

**Critical Kea Issues:**

- Direct state mutations (always return new objects)
- Missing error handling in async listeners
- Missing cleanup in afterUnmount
- Listeners without try/catch blocks

## Kea Logic Keys

**CRITICAL**: The `key()` function must create stable, predictable keys.

**Anti-patterns to avoid:**

```typescript
// ❌ BAD: Fragile - fails with circular refs, creates long keys
key((props) => JSON.stringify(props.value))

// ❌ BAD: Non-deterministic
key((props) => Math.random())

// ❌ BAD: Complex objects
key((props) => props.complexObject)  // Reference changes break mounting
```

**Best practices:**

```typescript
// ✅ GOOD: Simple primitive
key((props) => props.id)

// ✅ GOOD: Stable string combination
key((props) => `${props.type}-${props.id}`)

// ✅ GOOD: Predictable array serialization
key((props) => {
    const value = props.value
    if (value === null) return 'null'
    if (Array.isArray(value)) {
        return value.map(v => v ?? 'null').join('-')
    }
    return String(value)
})
```

**Why this matters:**

- Circular references crash with JSON.stringify
- Long keys waste memory and hurt performance
- Unstable keys cause unnecessary remounting
- Non-deterministic keys break component identity

## Props Synchronization

**CRITICAL**: Add `propsChanged` when logic receives props that can change externally.

**When to use propsChanged:**

- Logic receives a `value` prop from parent
- Parent component controls the state
- Props affect internal state that must stay in sync

**Missing propsChanged causes:**

- Component state diverging from parent
- Stale data displayed after prop updates
- User confusion from UI not reflecting changes

**Pattern:**

```typescript
propsChanged(({ actions, props }, oldProps) => {
    // Only sync when value actually changed
    if (props.value !== oldProps.value) {
        actions.updateInternalState(props.value)
    }

    // For complex values, use deep equality
    if (JSON.stringify(props.config) !== JSON.stringify(oldProps.config)) {
        actions.reloadWithNewConfig(props.config)
    }
}),
```

**Example - Form input logic:**

```typescript
const formInputLogic = kea({
    key: (props) => props.fieldName,
    props: {} as { value: string; onSet: (value: string) => void },

    actions: {
        setLocalValue: (value: string) => ({ value }),
    },

    reducers: ({ props }) => ({
        localValue: [
            props.value,
            {
                setLocalValue: (_, { value }) => value,
            },
        ],
    }),

    // IMPORTANT: Sync when parent changes value
    propsChanged(({ actions, props }, oldProps) => {
        if (props.value !== oldProps.value) {
            actions.setLocalValue(props.value)
        }
    }),

    listeners: ({ props }) => ({
        setLocalValue: ({ value }) => {
            props.onSet(value)
        },
    }),
})
```

