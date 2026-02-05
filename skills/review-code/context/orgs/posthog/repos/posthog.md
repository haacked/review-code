# posthog/posthog Repository Guidelines

## Development Workflow

When working on the <https://github.com/PostHog/posthog> repository:

- Read the README.md file in the root of the repository and the <https://github.com/PostHog/posthog/blob/master/docs/FLOX_MULTI_INSTANCE_WORKFLOW.md> file
- When taking on a new task, prompt the user whether they want to create a new git worktree using the `phw` command for the task

## Quality Checks

When completing a task, automatically run these checks and fix any issues:

- `mypy --version && mypy -p posthog | mypy-baseline filter || (echo "run 'pnpm run mypy-baseline-sync' to update the baseline" && exit 1)`
