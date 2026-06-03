# Webhook Performance Tester — Design Spec

## Purpose

A toolkit for deploying simulated admission webhooks on OpenShift clusters to measure, demonstrate, and diagnose the performance impact of validating and mutating webhooks. Targets two audiences: platform engineers diagnosing webhook latency, and customer-facing demos showing the cascading effect of webhook sprawl.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language | Python | Code mounted via ConfigMap onto a UBI base image — zero build step, zero registry dependency |
| Base image | `registry.access.redhat.com/ubi9/python-312` | Red Hat supported, available on OpenShift by default |
| TLS | OpenShift service serving certificates | Auto-generated, auto-rotated, CA bundle injected into webhook configs. No manual cert management |
| Scale model | One server pod, N webhook configurations | Each WebhookConfiguration registration adds a sequential admission call. Cascading latency with minimal resource footprint |
| Target resources | Pods and Deployments | Matches what Kyverno/OPA/Gatekeeper typically intercept |
| Namespace isolation | namespaceSelector with label `webhook-perf-test: "true"` | Webhooks only fire in the demo namespace, no impact on the rest of the cluster |
| Security context | Default restricted-v2 SCC | No elevated privileges needed. Non-root user, no host mounts, no privileged ports |

## Repository Structure

```
webhook-performance-tester/
├── deploy/
│   ├── 00-namespace.yaml
│   ├── 01-webhook-server.yaml
│   └── 02-webhook-config-template.yaml
├── scripts/
│   ├── setup.sh
│   ├── scale-webhooks.sh
│   ├── trigger.sh
│   ├── measure.sh
│   ├── demo.sh
│   └── teardown.sh
├── dashboards/
│   └── webhook-performance.json
├── docs/
│   ├── performance-queries.md
│   └── tested-versions.md
├── CLAUDE.md
└── README.md
```

## Components

### 1. Namespace (`deploy/00-namespace.yaml`)

Creates a dedicated namespace (e.g., `webhook-perf-test`) with the label `webhook-perf-test: "true"` used by webhook namespaceSelectors.

### 2. Webhook Server (`deploy/01-webhook-server.yaml`)

A single YAML manifest containing three resources:

**ConfigMap** — contains the Python webhook server script. The script:
- Runs an HTTPS server using the service serving cert
- Exposes two endpoints: `/validate` and `/mutate`
- Reads `WEBHOOK_DELAY_MS` env var, sleeps that duration per request
- `/validate` returns `allowed: true` (measuring latency, not enforcing policy)
- `/mutate` adds an annotation `webhook-test/processed-by: <webhook-name>` via JSON patch — demonstrates a realistic mutation and makes it visible which webhooks fired
- Logs each request: timestamp, webhook name, resource kind, delay applied, response time
- Uses only Python standard library (http.server, ssl, json) — no pip dependencies

**Deployment** — runs the UBI Python image with:
- Volume mount: ConfigMap → `/app/server.py`
- Volume mount: service serving cert Secret → `/etc/tls/`
- Command: `python3 /app/server.py`
- Port 8443
- Env vars: `WEBHOOK_DELAY_MS` (default `100`), `WEBHOOK_NAME` (default `webhook-test`)
- Runs as non-root, compatible with restricted-v2 SCC
- Readiness probe on the HTTPS port

**Service** — exposes port 443 → 8443 with annotation `service.beta.openshift.io/serving-cert-secret-name: webhook-server-cert` to trigger automatic TLS cert generation.

### 3. Webhook Configuration Template (`deploy/02-webhook-config-template.yaml`)

A template used by `scale-webhooks.sh` to generate webhook registrations. Contains placeholders for:
- Webhook name (e.g., `webhook-perf-validate-01`)
- Webhook type (ValidatingWebhookConfiguration or MutatingWebhookConfiguration)
- Service path (`/validate` or `/mutate`)

Each generated configuration:
- Targets the demo namespace via `namespaceSelector` matching `webhook-perf-test: "true"`
- Intercepts `CREATE` and `UPDATE` on Pods and Deployments in API groups `""` and `"apps"`
- Uses `failurePolicy: Ignore` to avoid locking up the cluster
- Has `service.beta.openshift.io/inject-cabundle: "true"` annotation for automatic CA bundle injection
- `sideEffects: None` for validating, `sideEffects: NoneOnDryRun` for mutating
- `admissionReviewVersions: ["v1"]`

### 4. Scripts

#### `setup.sh`
1. Creates the namespace
2. Applies the webhook server manifests (ConfigMap, Deployment, Service)
3. Waits for the service serving cert Secret to be created
4. Waits for the webhook server pod to be ready
5. Prints status summary

#### `scale-webhooks.sh N`
- Takes a single argument: number of webhook pairs to create
- Deletes any existing `webhook-perf-*` configurations (clean state each run)
- Generates N ValidatingWebhookConfigurations + N MutatingWebhookConfigurations from the template using `sed` substitution
- Applies them all
- Prints summary: "Created N validating + N mutating webhooks"

#### `trigger.sh [--count N]`
- Creates or restarts a sample Deployment (`registry.access.redhat.com/ubi9/pause`) in the target namespace
- `--count N` creates N separate Deployments to simulate burst activity
- Prints wall-clock time for the operation to complete
- Shows resulting annotations on the created pods (to see which mutating webhooks fired)

#### `measure.sh`
- Queries API server admission metrics via OpenShift Prometheus (thanos-querier route)
- Falls back to direct `/metrics` endpoint if Prometheus is not accessible
- Outputs formatted report:
  - Number of registered webhooks
  - Configured delay
  - Per-webhook P50/P95/P99 latency
  - Total validating step duration
  - Total mutating step duration
  - Combined admission overhead

#### `demo.sh`
- Guided walkthrough that runs setup → scale 1 → trigger → measure → scale 5 → trigger → measure → scale 10 → trigger → measure
- Pauses between steps with narration explaining what's happening
- Press Enter to advance
- Runs teardown at the end (with option to skip)

#### `teardown.sh`
- Deletes all `webhook-perf-*` webhook configurations
- Deletes the webhook server deployment, service, configmap
- Deletes the namespace
- Idempotent — safe to run multiple times

### 5. Grafana Dashboard (`dashboards/webhook-performance.json`)

Pre-built dashboard JSON for import into OpenShift user-workload monitoring Grafana or standalone Grafana. Panels:
- Webhook admission latency over time (per webhook name)
- Total admission step duration (validating vs mutating)
- Webhook call count rate
- Admission overhead as percentage of total API request time

### 6. Performance Queries Documentation (`docs/performance-queries.md`)

All queries from `measure.sh` documented with explanation, context, and example output. Organized by access method:
- **oc / kubectl commands** — listing webhooks, checking events, pod resource usage
- **Prometheus/PromQL** — queries against `apiserver_admission_webhook_admission_duration_seconds`, `apiserver_admission_step_admission_duration_seconds`, `apiserver_admission_webhook_rejection_count`
- **API server audit logs** — when enabled, how to correlate admission latency to specific requests
- **Interpretation guide** — what "good" vs "bad" numbers look like, when to worry

### 7. Tested Versions (`docs/tested-versions.md`)

Table tracking:
- OpenShift version
- Kubernetes version
- Date tested
- Notes / known issues

Initially empty — populated as clusters are tested.

## Env Var Reference

| Variable | Default | Set On | Description |
|---|---|---|---|
| `WEBHOOK_DELAY_MS` | `100` | Deployment | Simulated processing delay per admission request (milliseconds) |
| `WEBHOOK_NAME` | `webhook-test` | Deployment | Identifier used in logs and mutation annotations |
| `TLS_CERT_PATH` | `/etc/tls/tls.crt` | Deployment | Path to service serving certificate |
| `TLS_KEY_PATH` | `/etc/tls/tls.key` | Deployment | Path to service serving private key |

To change `WEBHOOK_DELAY_MS` on a running server:
```bash
oc set env deployment/webhook-server WEBHOOK_DELAY_MS=500 -n webhook-perf-test
```
This triggers a rolling update — the new pod picks up the new delay.

## Demo Narrative Flow

1. **Baseline** — deploy the server, register 1 validating + 1 mutating webhook, trigger a deployment, measure ~200ms overhead (2 × 100ms delay)
2. **Scale up** — register 5 pairs (10 total), trigger again, measure ~1000ms overhead. Same operation, 5x slower.
3. **Worst case** — register 10 pairs (20 total), trigger again, measure ~2000ms overhead. Point out that this is *per API call*, and a single `oc apply` or deployment rollout can involve multiple API calls.
4. **Slow policy engine** — set `WEBHOOK_DELAY_MS=500` to simulate a policy engine under load. Even 2 webhooks now add 1000ms. At 10 webhooks, that's 5 seconds per API call.
5. **Diagnostic walkthrough** — use `measure.sh` and the documented queries to show how you'd identify which webhooks are slow on a real cluster.

## Out of Scope

- Actual policy enforcement logic (this is a performance testing tool, not a policy engine)
- Custom RBAC beyond default restricted-v2 SCC
- Container image builds or registry publishing
- Vanilla Kubernetes support (OpenShift-specific TLS and monitoring paths; could be extended later)
- Webhook configurations targeting resources outside the demo namespace
