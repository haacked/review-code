## Dependency Management

**Critical checks:**

- Run `cargo shear` - unused deps indicate design problems
- Verify Cargo features actually enable code that exists
- Check new dependencies are actually imported/used
- Avoid `cargo shear` ignores without strong justification

**Golden rule:** If `cargo shear` wants to remove it, either use it properly or remove it.

## Error Handling

**Idiomatic patterns:**

- Use `Result<T, E>` for recoverable errors
- Use `?` operator for error propagation
- Implement `std::error::Error` for custom errors
- Prefer `anyhow` or `thiserror` over custom types

**Anti-patterns:**

- Unwrapping without justification (use `expect` with message)
- Silently ignoring errors
- Panic in library code
- Using `unwrap()` on production code paths

## Ownership & Lifetimes

**Common issues:**

- Unnecessary cloning (pass references instead)
- Fighting the borrow checker (redesign data flow)
- Complex lifetime annotations (simplify structure)
- Mixing `&T` and `&mut T` incorrectly

**Patterns:**

- Use `&str` for string parameters, `String` for owned
- Prefer borrowing over `Clone` when possible
- Use `Cow<'_, T>` for conditional ownership

## Async Patterns

**Critical checks:**

- Blocking operations in async functions (use `spawn_blocking`)
- Missing `.await` on futures
- Holding locks across `.await` points (causes deadlocks)
- Not using `tokio::select!` for cancellation

**Common mistakes:**

- Mixing async runtimes (stick to one)
- CPU-intensive work in async functions
- Not handling cancellation properly

## Type Safety

**Leverage the type system:**

- Use newtypes for domain concepts
- `Option<T>` instead of nullable patterns
- Enums for state machines
- Type aliases for complex types

**Anti-patterns:**

- Stringly-typed code
- Using `as` casts unsafely
- Ignoring compiler warnings about unused results

## Testing Patterns

**Rust testing:**

- Unit tests in the same file with `#[cfg(test)]`
- Integration tests in `tests/` directory
- Use `#[should_panic]` for error conditions
- Mock traits, not structs

**Test organization:**

- Test modules named `tests`
- One assertion per test when possible
- Use descriptive test names

## Performance

**Common optimizations:**

- Use iterators instead of loops (lazy evaluation)
- `Vec` pre-allocation with `with_capacity`
- Avoid unnecessary allocations
- Use `&[T]` slices instead of `Vec<T>` in signatures

**Profiling:**

- Profile before optimizing
- Use `cargo flamegraph` for CPU profiling
- Check for unnecessary clones with `cargo clippy`

## Quality Checklist

**Before committing:**

- `cargo fmt` - format code
- `cargo clippy --all-targets --all-features -- -D warnings` - fix all warnings
- `cargo shear` - check for unused dependencies
- Verify Cargo features enable real functionality
- Run tests with `cargo test`

## Common Clippy Warnings

**Address these:**

- `needless_borrow` - unnecessary `&`
- `unnecessary_unwrap` - use pattern matching
- `large_enum_variant` - box large variants
- `too_many_arguments` - use a struct

## Idioms

**Rust conventions:**

- Use `impl Trait` for return types
- Implement `From` and `Into` for conversions
- Use `Default` trait for initialization
- Derive `Debug`, `Clone` where appropriate
- Follow naming conventions (snake_case, CamelCase)

## Derive Awareness (Critical)

**The most common source of unnecessary complexity in Rust:** Manual code that reimplements what a derive macro already provides.

**Detection signals:**

- Field-name string literals: `.get("user_id")` matching struct fields
- Repetitive per-field operations: N similar `.get().and_then()` calls
- Disproportionate line count: 50+ lines for a simple type conversion
- Error messages naming fields: `"Missing 'id' field"`

**Common patterns to flag:**

| If struct has... | Flag this manual pattern | Use instead |
|------------------|--------------------------|-------------|
| `#[derive(Deserialize)]` | `.get("field").and_then(\|v\| v.as_*())` chains | `serde_json::from_value()` |
| `#[derive(Serialize)]` | Manual `serde_json::json!{}` or HashMap building | `serde_json::to_value()` |
| `#[derive(Clone)]` | `Self { a: self.a.clone(), b: self.b, ... }` | `.clone()` |
| `#[derive(Default)]` | `Self { a: 0, b: String::new(), ... }` | `Default::default()` |
| `#[derive(FromRow)]` | Manual `row.get("column")` extraction | Let sqlx use the derive |
| `#[derive(Debug)]` | Manual `fmt::Debug` impl with same output | Remove manual impl |

**The test:** For any conversion/parsing function, ask: "Does a derive already handle this?"

**Example - what to catch:**

```rust
// RED FLAG: Struct has Deserialize but function does manual parsing
#[derive(Deserialize)]
pub struct Team { id: i32, name: String, /* 30 fields */ }

// This 150-line function should be 3 lines:
pub fn from_json(value: Value) -> Result<Team, Error> {
    let obj = value.as_object().ok_or(Error::Parse)?;
    let id = obj.get("id").and_then(|v| v.as_i64())...;  // repeated 30x
    // ... 140 more lines of manual field extraction ...
}

// CORRECT: Use the derive
pub fn from_json(value: Value) -> Result<Team, Error> {
    serde_json::from_value(value).map_err(|e| Error::Parse(e.to_string()))
}
```

**Why this matters:**

- Manual parsing is 50x more code
- Manual parsing misses edge cases serde handles (nulls, missing fields, type coercion)
- Manual parsing must be updated when struct fields change
- Serde is battle-tested; manual code is not
