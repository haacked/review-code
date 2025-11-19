---
name: code-reviewer
description: Deprecated - use /review-code command instead for comprehensive code review
model: sonnet
color: blue
---

This general code-reviewer agent has been **deprecated** in favor of specialized code review agents that provide deeper, more focused analysis.

## Please use the `/review-code` command instead

The `/review-code` command orchestrates all 5 specialized code review agents:

1. **code-reviewer-security** - Deep security vulnerability analysis
2. **code-reviewer-performance** - Performance bottlenecks and optimization
3. **code-reviewer-maintainability** - Code clarity, simplicity, and long-term health
4. **code-reviewer-testing** - Test coverage, quality, and patterns
5. **code-reviewer-frontend** - React/Kea patterns and frontend best practices

### Usage

**Comprehensive review (recommended):**
```
/review-code
```
Runs all 5 specialized agents sequentially for complete coverage.

**Targeted review:**
```
/review-code security          # Security only
/review-code performance       # Performance only
/review-code maintainability   # Maintainability only
/review-code testing           # Testing only
/review-code frontend          # Frontend only
```

## Why the change?

The specialized agents provide:
- **Deeper expertise** in each area (security, performance, etc.)
- **More specific guidance** with concrete examples
- **Better coverage** of edge cases and patterns
- **Optimized prompts** for each concern area
- **Shared context** (git diff, PostHog-specific info) passed efficiently

## What was migrated?

All valuable content from the general agent has been incorporated into specialized agents:
- **Correctness & logic errors** → code-reviewer-maintainability
- **Rust dependency management** → code-reviewer-maintainability
- **Security vulnerabilities** → code-reviewer-security (enhanced)
- **Performance issues** → code-reviewer-performance (enhanced)
- **PostHog-specific context** → Passed via /review-code command

---

**Bottom line:** Use `/review-code` for better, more comprehensive code reviews.
