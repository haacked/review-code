## React Component Architecture

**Critical Issues:**

- Components doing too much (violating single responsibility)
- Missing error boundaries for error-prone sections
- Direct DOM manipulation instead of React patterns
- Missing or incorrect key props in lists

**Split large components:**

- Container components for data/state
- Presentational components for pure rendering

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

## Performance & Re-rendering

**Important optimizations:**

- useMemo for expensive calculations
- useCallback for event handlers passed as props
- React.memo for components that re-render often
- Missing dependency arrays causing infinite loops
- Unnecessary state causing re-renders

## Hooks Usage & Patterns

**Critical hook violations:**

- Hooks called conditionally or in loops
- Missing dependency arrays
- Missing cleanup functions in useEffect

**Common mistakes:**

- Using useEffect for derived state (use useMemo)
- useEffect doing too much (split them)
- Creating new functions on every render
- Using useState when useRef is appropriate

## TypeScript & Props Management

**Type safety issues:**

- Props without proper TypeScript types
- Using `any` instead of proper interfaces
- Missing null/undefined checks
- Props spreading losing type safety

## PostHog-Specific Patterns

**LemonUI Components:**

- Use LemonButton, LemonInput, etc. instead of custom implementations
- Follow Lemon design tokens

**Scene Pattern:**

- Proper scene registration
- Scene logic cleanup
- Scene parameters in URLs

**Feature Flags:**

- Check feature flags correctly
- Provide fallback behavior
- Clean up when features toggle

## Common Anti-Patterns

**useEffect misuse:**

- Using for derived state (use useMemo)
- Missing cleanup for subscriptions/timers
- Multiple useEffects that should be combined

**Event handlers:**

- Inline arrow functions in JSX (causes re-renders)
- Missing event.preventDefault() when needed

**Forms:**

- Controlled inputs without onChange
- Missing debouncing for search inputs

## Accessibility Requirements

- Interactive elements need ARIA labels
- Modals trap focus and close with ESC
- Forms have associated labels
- Error messages announced to screen readers
- Keyboard navigation preserved
