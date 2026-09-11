# PostHog Organization Guidelines

## Production Infrastructure

PostHog production runs behind load balancers and proxies. Keep this in mind for any code that touches IP addresses, rate limiting, authentication, or geolocation.

### Architecture Stack

**AWS Network Load Balancer (NLB)** → **Contour/Envoy Ingress** → **Application Pods**

- Contour is configured with `num-trusted-hops: 1` to properly extract client IPs from headers
- NLB preserves client IPs via `preserve_client_ip.enabled=true`

### Client IP Detection

The socket IP is always the load balancer's address, never the client's. Code that uses it for rate limiting puts every client in one bucket (attackers bypass the limit, legitimate users get throttled together); for IP-based authentication or geo-blocking, it grants or denies everyone at once; in security logs, it corrupts the audit trail for incident response. Flag any of these, and flag hand-rolled IP detection when the ecosystem has a vetted extractor (Rust: `tower_governor::key_extractor::SmartIpKeyExtractor`; look for similar "smart" extractors in other languages).

Client IP precedence:

1. `X-Forwarded-For` (primary, set by load balancer/proxy)
2. `X-Real-IP` (fallback)
3. `Forwarded` (RFC 7239 standard format)
4. Socket IP (local development only)

When reviewing IP handling, also check for protection against header spoofing and that security logs capture the real client IP.

### Infrastructure Repository References

When reviewing networking, IP handling, or infrastructure-related code, consult these repos:

- **`~/dev/posthog/posthog-cloud-infra`** - Terraform/AWS infrastructure
  - Contains: NLB config, VPC setup, load balancer settings
  - See: `README.md` for architecture diagram

- **`~/dev/posthog/charts`** - Helm charts and K8s deployment configs
  - Contains: Contour/Envoy configuration, ingress rules, header policies, pod lifecycle values, resource limits
  - Key files:
    - `argocd/contour/values/values.yaml` - num-trusted-hops config
    - `argocd/contour-ingress/values/values.prod-*.yaml` - routing and header policies
    - `docs/CONTOUR-GEOIP-README.md` - GeoIP and header handling
    - `charts/posthog-rust/templates/deployment.yaml` - pod defaults for Rust services (grace period, resources; current values in `repos/charts.md`)

## Performance Guidelines

### ClickHouse Query Optimization

- Verify proper use of materialized columns
- Check for missing PREWHERE clauses
- Ensure proper partition key usage
- Look for unnecessary distributed table queries

### Event Processing Performance

- Check for missing batch processing opportunities
- Verify proper Kafka consumer configuration
- Look for synchronous processing that could be async
- Check for missing circuit breakers on external calls

## UI Patterns

### LemonUI Components

- Use LemonButton, LemonInput, etc. instead of custom implementations
- Follow Lemon design tokens

### Scene Pattern

- Proper scene registration
- Scene logic cleanup
- Scene parameters in URLs

### Feature Flags

- Check feature flags correctly
- Provide fallback behavior
- Clean up when features toggle

Kea state management guidance lives in the kea framework context, which loads whenever Kea is detected in the diff.

## SDK Repositories

PostHog has client-side and server-side SDKs:

### Client-side SDKs

| Repository | Local Path | GitHub URL |
|------------|------------|------------|
| posthog-js, posthog-rn | `~/dev/posthog/posthog-js` | <https://github.com/PostHog/posthog-js> |
| posthog-ios | `~/dev/posthog/posthog-ios` | <https://github.com/PostHog/posthog-ios> |
| posthog-android | `~/dev/posthog/posthog-android` | <https://github.com/PostHog/posthog-android> |
| posthog-flutter | `~/dev/posthog/posthog-flutter` | <https://github.com/PostHog/posthog-flutter> |

### Server-side SDKs

| Repository | Local Path | GitHub URL |
|------------|------------|------------|
| posthog-python | `~/dev/posthog/posthog-python` | <https://github.com/PostHog/posthog-python> |
| posthog-node | `~/dev/posthog/posthog-js` | <https://github.com/PostHog/posthog-node> |
| posthog-php | `~/dev/posthog/posthog-php` | <https://github.com/PostHog/posthog-php> |
| posthog-ruby | `~/dev/posthog/posthog-ruby` | <https://github.com/PostHog/posthog-ruby> |
| posthog-go | `~/dev/posthog/posthog-go` | <https://github.com/PostHog/posthog-go> |
| posthog-dotnet | `~/dev/posthog/posthog-dotnet` | <https://github.com/PostHog/posthog-dotnet> |
| posthog-elixir | `~/dev/posthog/posthog-elixir` | <https://github.com/PostHog/posthog-elixir> |
