# PostHog Organization Guidelines

## Production Infrastructure

**CRITICAL**: PostHog production runs behind load balancers and proxies. Always consider this when implementing features that involve IP addresses, rate limiting, authentication, or geolocation.

### Architecture Stack

**AWS Network Load Balancer (NLB)** → **Contour/Envoy Ingress** → **Application Pods**

- Contour is configured with `num-trusted-hops: 1` to properly extract client IPs from headers
- NLB preserves client IPs via `preserve_client_ip.enabled=true`

### Client IP Detection (Security Critical)

**CRITICAL**: Socket IPs are always the load balancer's IP, never the actual client IP.

**NEVER use socket IP addresses** - they will always be the load balancer's IP, not the client's IP.

**ALWAYS use X-Forwarded-For headers** in this precedence:

1. `X-Forwarded-For` (primary, set by load balancer/proxy)
2. `X-Real-IP` (fallback)
3. `Forwarded` (RFC 7239 standard format)
4. Socket IP (last resort only for local development)

**Common Libraries:**

- Rust: `tower_governor::key_extractor::SmartIpKeyExtractor`
- Look for similar "smart" IP extractors in other languages

### Common Pitfalls to Avoid

- ❌ Using socket IP for rate limiting → all requests share one rate limit
- ❌ Using socket IP for authentication → security bypass
- ❌ Using socket IP for geolocation → all traffic appears from one location
- ❌ Implementing custom IP detection → reinventing the wheel, likely buggy

### Security Vulnerabilities from Incorrect IP Handling

- **Rate Limit Bypass**: Using socket IP allows attackers to bypass rate limits (all traffic shares one bucket)
- **Authentication Bypass**: IP-based auth using socket IP grants access to anyone
- **Audit Trail Corruption**: Incorrect IPs in security logs impede incident response
- **Geographic Restrictions Bypass**: IP-based geo-blocking becomes ineffective

**Example Critical Issue:**

```text
🔴 CRITICAL: Authentication bypass via socket IP usage (auth.rs:89)

Vulnerability: IP allowlist check uses socket address instead of real client IP
Impact: Complete authentication bypass for restricted endpoints

Fix:
- let client_ip = req.socket_addr().ip();  // VULNERABLE
+ let client_ip = SmartIpKeyExtractor::extract(&req);  // SECURE
```

### Infrastructure Security Checklist

- [ ] Proper header extraction for client identification?
- [ ] Protection against header spoofing attacks?
- [ ] Rate limiting applied per real client, not load balancer?
- [ ] Security logs capture actual client IPs for forensics?

### Infrastructure Repository References

When reviewing networking, IP handling, or infrastructure-related code, consult these repos:

- **`~/dev/posthog/posthog-cloud-infra`** - Terraform/AWS infrastructure
  - Contains: NLB config, VPC setup, load balancer settings
  - See: `README.md` for architecture diagram

- **`~/dev/posthog/charts`** - Helm charts and K8s deployment configs
  - Contains: Contour/Envoy configuration, ingress rules, header policies
  - Key files:
    - `argocd/contour/values/values.yaml` - num-trusted-hops config
    - `argocd/contour-ingress/values/values.prod-*.yaml` - routing and header policies
    - `docs/CONTOUR-GEOIP-README.md` - GeoIP and header handling

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
