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
