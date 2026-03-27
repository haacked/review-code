# PostHog/charts Repository Guidelines

## Repository Overview

This repository contains Helm charts and Kubernetes deployment configurations for PostHog's infrastructure, managed via ArgoCD.

## Environment Structure

<!-- TODO: Fill in environment details -->

PostHog deploys across multiple environments:
- **dev** - Development/staging environment
- **prod-us** - US production region
- **prod-eu** - EU production region

Most changes should be applied consistently across all three environments unless intentionally staged.

## Directory Layout

<!-- TODO: Verify and expand directory structure -->

```
argocd/
  <service>/
    values/
      values.yaml          # Base/shared values
      values.dev.yaml      # Dev-specific overrides
      values.prod-us.yaml  # US production overrides
      values.prod-eu.yaml  # EU production overrides
  contour-ingress/
    values/
      values.dev.yaml      # Dev ingress routing
      values.prod-us.yaml  # US production routing
      values.prod-eu.yaml  # EU production routing
```

## Contour Ingress Patterns

<!-- TODO: Fill in Contour/HTTPProxy conventions -->

Contour is used as the ingress controller with Envoy as the data plane. Route changes in `argocd/contour-ingress/values/` affect traffic routing.

Key considerations:
- Route changes should typically be applied to all 3 environment files
- `num-trusted-hops: 1` is configured for proper client IP extraction
- Routes map URL paths to Kubernetes services

## Fleet and Service Naming

<!-- TODO: Fill in fleet/service naming conventions -->

Services follow the naming pattern `posthog-<service-name>`. Examples:
- `posthog-feature-flags`
- `posthog-feature-flags-definitions`

## Common Environment Variables

<!-- TODO: Document common env vars -->

- `SERVICE_MODE` - Controls which routes a service registers (e.g., `"flags"` for flags-only mode)

## Cross-Environment Consistency

When reviewing changes:
1. Verify route changes are present in all 3 environment files (dev, prod-us, prod-eu)
2. Check that service names reference actual deployed services
3. Confirm environment variable additions are propagated to all relevant deployments
4. Note any intentional per-environment differences (e.g., staged rollouts)
