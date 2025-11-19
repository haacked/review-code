# Customization Guide: Adding Organization and Repository Context

This guide explains how to add custom context for your organization and repositories to get more relevant code reviews.

## Overview

Review-code loads context in this hierarchical order:

1. **Language** → Generic language patterns (Python, TypeScript, etc.)
2. **Framework** → Generic framework patterns (Django, React, etc.)
3. **Organization** → Your org's specific guidelines
4. **Repository** → Specific repo's workflows and standards

Each level is optional and additive. Generic context is always loaded first, with more specific context layered on top.

## Directory Structure

```
~/.review-code/context/
├── languages/           # Generic language guidelines (built-in)
│   ├── python.md
│   ├── typescript.md
│   └── ...
├── frameworks/          # Generic framework guidelines (built-in)
│   ├── django.md
│   ├── react.md
│   └── ...
└── orgs/               # Organization-specific context (you add these)
    ├── your-org/
    │   ├── org.md      # Organization-wide guidelines
    │   └── repos/
    │       ├── repo-one.md    # Repo-specific guidelines
    │       └── repo-two.md
    └── another-org/
        └── org.md
```

## Adding Organization Context

### 1. Create Organization Directory

```bash
mkdir -p ~/.review-code/context/orgs/your-org-name/repos
```

**Important**: Use lowercase for the directory name. The system automatically converts org names to lowercase for matching.

### 2. Create `org.md` File

Create `~/.review-code/context/orgs/your-org-name/org.md`:

```markdown
# Your Organization Guidelines

## Architecture Patterns

Describe your organization's standard architecture patterns:

- Microservices vs monolith
- API design standards
- Database choices
- Message queue usage

## Security Requirements

### Authentication

- OAuth2 with specific providers
- JWT token standards
- Session management rules

### Secrets Management

- How to handle API keys
- Where secrets should be stored
- Secret rotation policies

## Performance Standards

### Database Queries

- Query timeout limits
- Index requirements
- Query complexity guidelines

### API Response Times

- p95 latency targets
- Caching strategies
- Rate limiting standards

## Infrastructure Context

### Production Environment

Describe your production infrastructure:

- Load balancer → Application → Database
- CDN configuration
- Geographic distribution

### Critical Considerations

List infrastructure-specific concerns:

- IP address handling (if behind load balancers/proxies)
- Header requirements
- Health check endpoints

## UI/UX Standards

### Design System

- Component library to use
- Design tokens
- Accessibility requirements

### User Experience

- Mobile responsiveness requirements
- Browser support matrix
- Performance budgets

## Technology Stack

List your standard technologies:

### Backend

- Primary languages
- Web frameworks
- Database systems
- Caching systems

### Frontend

- JavaScript frameworks
- State management
- Build tools

### DevOps

- CI/CD platforms
- Container orchestration
- Monitoring tools

## Code Style and Conventions

### Naming Conventions

- File naming patterns
- Variable naming rules
- Class/function naming standards

### Documentation Standards

- README requirements
- API documentation format
- Inline comment guidelines

## Repository References

If you have infrastructure or documentation repos, list them:

- `~/dev/your-org/infrastructure` - Terraform/AWS configuration
- `~/dev/your-org/k8s-manifests` - Kubernetes deployments
- `~/dev/your-org/docs` - Technical documentation
```

### 3. Test Organization Context

Make a change in any repo belonging to your organization and run:

```bash
/review-code
```

The review should include your org-specific context automatically.

## Adding Repository Context

For repo-specific guidelines, create a file for each repo.

### 1. Create Repository File

Create `~/.review-code/context/orgs/your-org-name/repos/repo-name.md`:

```markdown
# your-org/repo-name Repository Guidelines

## Development Workflow

### Testing Requirements

- All changes must have tests
- Test coverage minimum: 80%
- Run specific test commands before commit

### Code Quality Checks

Commands to run before committing:

```bash
npm run lint
npm run type-check
npm test
```

### Branch Naming

- Feature branches: `feature/description`
- Bug fixes: `fix/issue-number-description`
- Hotfixes: `hotfix/description`

## Architecture Specific to This Repo

### Module Structure

Explain this repo's module organization:

```
src/
├── api/          # REST API endpoints
├── services/     # Business logic
├── models/       # Data models
└── utils/        # Shared utilities
```

### Key Components

Describe important components:

- Authentication middleware
- Database connection pool
- Cache layer
- Background job processor

## Database

### Migrations

- Migration naming convention
- How to create migrations
- Migration review process

### Schema Conventions

- Table naming patterns
- Column naming rules
- Index naming standards

## Dependencies

### Approved Libraries

List libraries that should be used:

- HTTP client: `axios`
- Testing: `jest`
- Date handling: `date-fns`

### Deprecated Libraries

List libraries to avoid:

- ❌ Don't use: `moment` (use `date-fns` instead)
- ❌ Don't use: `request` (deprecated, use `axios`)

## Deployment

### Environment Variables

Required environment variables:

- `DATABASE_URL`
- `API_KEY`
- `REDIS_URL`

### Pre-deployment Checklist

- [ ] All tests pass
- [ ] Database migrations tested
- [ ] Environment variables documented
- [ ] Changelog updated

## Common Pitfalls

List repo-specific issues to watch for:

### Database Connection Pooling

This repo uses a custom connection pool. Always use `getConnection()` instead of creating new connections.

### Cache Invalidation

When updating `User` model, remember to invalidate cache:

```python
cache.delete(f"user:{user.id}")
```

## Related Repositories

- Main app: `your-org/main-app`
- API gateway: `your-org/api-gateway`
- Shared libraries: `your-org/shared-utils`
```

### 2. Test Repository Context

Navigate to the repository and run:

```bash
/review-code
```

The review should include both org-level and repo-level context.

## Example: Complete Organization Setup

Here's a complete example for a fictional company "Acme Corp":

### Directory Structure

```
~/.review-code/context/orgs/acme/
├── org.md
└── repos/
    ├── web-app.md
    ├── api.md
    └── mobile-app.md
```

### org.md (Organization-Wide)

```markdown
# Acme Corporation Guidelines

## Security Requirements

All Acme services run behind AWS ALB. **Never use socket IP addresses** for:

- Rate limiting
- Authentication
- Geolocation

Always extract client IP from `X-Forwarded-For` header.

## Performance Standards

- API responses: p95 < 200ms
- Database queries: < 100ms
- Page load time: < 2s

## Technology Stack

- Backend: Python 3.11+, FastAPI
- Frontend: React 18+, TypeScript
- Database: PostgreSQL 15+
- Cache: Redis
- Queue: Celery + Redis
```

### repos/web-app.md (Repo-Specific)

```markdown
# acme/web-app Repository Guidelines

## Testing

Run before every commit:

```bash
npm run lint
npm run type-check
npm test
```

Minimum coverage: 80%

## Component Library

Always use Acme UI components:

- `<AcmeButton>` instead of `<button>`
- `<AcmeInput>` instead of `<input>`
- Follow design tokens in `src/theme/tokens.ts`

## State Management

- Use React hooks for local state
- Use Redux for global state
- Use React Query for server state

Never mix paradigms in a single component.
```

## How Context Loading Works

When you run `/review-code` on `acme/web-app` with TypeScript and React code:

1. **Language Context**: Loads `languages/typescript.md`
2. **Framework Context**: Loads `frameworks/react.md`
3. **Org Context**: Loads `orgs/acme/org.md`
4. **Repo Context**: Loads `orgs/acme/repos/web-app.md`

All four are combined and passed to the review agents, so they have:

- Generic TypeScript best practices
- Generic React patterns
- Acme's security and performance requirements
- Web-app-specific testing and component guidelines

## Tips for Writing Good Context

### Be Specific

❌ Bad: "Use good error handling"
✅ Good: "Wrap all API calls in try/catch, log to DataDog, return user-friendly message"

### Include Examples

```markdown
### API Error Handling

❌ Bad:
```python
result = api.call()
```

✅ Good:
```python
try:
    result = api.call()
except APIError as e:
    logger.error(f"API call failed: {e}", extra={"trace_id": trace_id})
    return {"error": "Service temporarily unavailable"}
```

### Link to Documentation

```markdown
See [API Guidelines](https://docs.acme.com/api-guidelines) for complete standards.
```

### Keep It Current

- Review and update quarterly
- Remove deprecated practices
- Add new patterns as they're adopted

### Focus on Common Issues

Don't try to document everything. Focus on:

- Frequent mistakes
- Security-critical patterns
- Performance bottlenecks
- Team-specific conventions

## Validating Your Context

### Test with Known Issues

Make a change that violates your guidelines and run `/review-code`. The review should catch it.

### Example Test

If your org.md says "Always use prepared statements for SQL", test with:

```python
# This should be flagged
query = f"SELECT * FROM users WHERE id = {user_input}"
```

Run `/review-code security` and verify the agent flags the SQL injection risk.

### Check Context Loading

Run a review with verbose output to see what context was loaded:

```bash
# The review should show which contexts were applied
/review-code
```

Look for sections like "Acme Organization Guidelines" in the agent output.

## Troubleshooting

### Context Not Loading

**Check directory name matches git remote**:

```bash
# Get your org name
git remote get-url origin
# Should match: ~/.review-code/context/orgs/<org-name>/
```

**Directory names are case-insensitive**: `PostHog` and `posthog` both match `orgs/posthog/`

### Wrong Repository Context Loading

**Check repo name matches exactly**:

```bash
# Get repo name
basename $(git remote get-url origin) .git
# Should match: orgs/<org>/repos/<repo-name>.md
```

### Context Not Being Used by Agents

Ensure your context follows Markdown formatting:

- Use proper headings (##, ###)
- Include code blocks with backticks
- Use lists for checklist items

## Advanced: Multiple Organizations

If you work with multiple organizations:

```
orgs/
├── acme/
│   ├── org.md
│   └── repos/
│       └── web-app.md
├── widgets-inc/
│   ├── org.md
│   └── repos/
│       └── api.md
└── startup-xyz/
    └── org.md
```

Context is loaded based on the current repository's git remote URL. No manual selection needed.

## Next Steps

- Start with org.md for organization-wide patterns
- Add repo-specific context as you encounter common review feedback
- Iterate based on what agents miss or incorrectly flag
- Share your org context with your team

## Resources

- [Main Documentation](./review-code-standalone.md)
- [Helper Scripts](../bin/) for understanding how detection works
