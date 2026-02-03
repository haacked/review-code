# Learnings Directory

This directory stores learning data from code review outcomes. Files are created per-installation (not committed to git).

## Files

### `index.jsonl`

Append-only file of individual learnings from PR analysis. Each line is a JSON object:

```json
{
  "timestamp": "2026-02-02T10:30:00Z",
  "pr_number": 123,
  "org": "posthog",
  "repo": "posthog",
  "type": "false_positive | missed_pattern | valid_catch | deferred",
  "source": "claude | other_reviewer",
  "agent": "security",
  "finding": {
    "file": "auth.py",
    "line": 45,
    "description": "SQL injection warning"
  },
  "context": {
    "language": "python",
    "framework": "django"
  },
  "user_feedback": "Django ORM auto-parameterizes queries"
}
```

**Types:**
- `valid_catch`: Claude found issue, code was fixed
- `false_positive`: Claude found issue, user confirmed it's incorrect
- `deferred`: Claude found issue, valid but low priority/deferred
- `missed_pattern`: Other reviewer found issue Claude missed, code was fixed

### `analyzed.json`

Tracks which PRs have been analyzed to avoid re-processing:

```json
{
  "posthog/posthog": {
    "123": "2026-02-02T10:30:00Z",
    "456": "2026-02-03T14:00:00Z"
  },
  "haacked/review-code": {
    "22": "2026-02-01T09:15:00Z"
  }
}
```

## Data Flow

1. `/review-code learn 123` analyzes PR #123 outcomes
2. Interactive prompts categorize uncertain findings
3. Learnings appended to `index.jsonl`
4. PR marked as analyzed in `analyzed.json`
5. `/review-code learn --apply` synthesizes patterns into context updates
