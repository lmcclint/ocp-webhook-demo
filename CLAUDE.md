# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Webhook performance testing toolkit for OpenShift. Deploys simulated admission webhooks with configurable latency to measure and demonstrate the cascading performance impact of webhook sprawl. No image builds — Python server code is delivered via ConfigMap onto a UBI base image.

## Architecture

- `deploy/` — Kubernetes/OpenShift YAML manifests (namespace, webhook server ConfigMap+Deployment+Service, webhook config templates)
- `scripts/` — Bash scripts for setup, scaling, triggering, measurement, demo, and teardown
- `dashboards/` — Grafana dashboard JSON
- `docs/` — Performance query reference and tested version tracking

The webhook server is a single Python script (`deploy/01-webhook-server.yaml` ConfigMap) using only stdlib (http.server, ssl, json). It handles `/validate`, `/mutate`, and `/healthz` endpoints.

Scaling works by registering N ValidatingWebhookConfiguration + N MutatingWebhookConfiguration resources, all pointing at the same server pod. The `scale-webhooks.sh` script generates these from `deploy/02-webhook-config-template.yaml` using sed substitution.

## Key Conventions

- All scripts use `#!/usr/bin/env bash` with `set -euo pipefail`
- Scripts reference the deploy directory relative to their own location via `SCRIPT_DIR`
- Namespace is `webhook-perf-test` with label `webhook-perf-test: "true"` for webhook selectors
- Webhook configurations use the `app=webhook-perf-test` label for bulk operations
- TLS via OpenShift service serving certificates (annotation-driven, auto-generated)
- The Python server has zero external dependencies — stdlib only
- Target platform is OpenShift; uses `oc` CLI throughout (not `kubectl`)

## Testing

No automated test suite — this is a deployment toolkit. Testing is done by running on an OpenShift cluster:

```bash
./scripts/setup.sh
./scripts/scale-webhooks.sh 1
./scripts/trigger.sh
./scripts/measure.sh
./scripts/teardown.sh
```

## Common Tasks

```bash
# Change webhook delay on a running server
oc set env deployment/webhook-server WEBHOOK_DELAY_MS=500 -n webhook-perf-test

# Check webhook server logs
oc logs deployment/webhook-server -n webhook-perf-test

# List all webhook-perf-test webhook configs
oc get validatingwebhookconfiguration -l app=webhook-perf-test
oc get mutatingwebhookconfiguration -l app=webhook-perf-test
```
