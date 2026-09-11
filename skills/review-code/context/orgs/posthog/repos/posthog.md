# posthog/posthog Repository Guidelines

## Development Workflow

When working on the <https://github.com/PostHog/posthog> repository:

- Read the README.md file in the root of the repository and the <https://github.com/PostHog/posthog/blob/master/docs/FLOX_MULTI_INSTANCE_WORKFLOW.md> file
- When taking on a new task, prompt the user whether they want to create a new git worktree using the `phw` command for the task

## Quality Checks

When completing a task, automatically run these checks and fix any issues:

- `mypy --version && mypy -p posthog | mypy-baseline filter || (echo "run 'pnpm run mypy-baseline-sync' to update the baseline" && exit 1)`

## Data Model

### Teams and projects are 1-1

Environments (several `posthog_team` rows under one `posthog_project`) are deprecated. Production has zero projects with more than one team, and every team's `id` equals its `project_id` (verified 2026-08-24 against US and EU: 521,525 US teams / 521,525 projects, 230,898 EU teams / 230,898 projects).

So `team_id` and `project_id` are interchangeable. On a `routers.projects` route, `self.team_id` resolving to `project_id` is not a scoping bug. Don't flag a query that scopes to a single team as missing sibling environments, and don't flag it as undercounting against a project- or org-level total. This is a recurring false positive.
