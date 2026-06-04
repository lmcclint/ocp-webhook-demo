# Webhook Performance Tester

A toolkit for measuring and demonstrating the performance impact of admission webhooks on OpenShift clusters.

Deploys a simulated webhook server with configurable latency, registers multiple validating and mutating webhook configurations to demonstrate cascading effects, and provides scripts and queries to measure the impact.

## Prerequisites

- OpenShift cluster with `cluster-admin` access
- `oc` CLI installed and logged in

### Dashboard (optional but recommended)

The demo includes a Perses dashboard that visualizes webhook latency, call rate, and rejections in real time. It requires the **Cluster Observability Operator (COO)** with the Perses UI plugin enabled.

If COO is not installed on your cluster:

```bash
# Install COO and enable Perses UI plugin
oc apply -f deploy/coo-perses/01-coo.yaml
oc apply -f deploy/coo-perses/02-coo-uiplugin-perses.yaml

# Wait for the operator to be ready (~2-3 minutes)
oc get csv -n openshift-cluster-observability-operator -w
```

Once the CSV shows `Succeeded`, the dashboard will be deployed automatically by `setup.sh` and is accessible in the OpenShift console under **Observe → Dashboards (Perses)**.

A standalone Grafana JSON is also available at [dashboards/webhook-performance-grafana.json](dashboards/webhook-performance-grafana.json) if you prefer Grafana.

## Quick Start

```bash
# Deploy the webhook server (and dashboard if Perses is available)
./scripts/setup.sh

# Register 5 validating + 5 mutating webhooks (100ms delay each)
./scripts/scale-webhooks.sh 5

# Trigger the webhooks by deploying a sample app
./scripts/trigger.sh

# Measure the latency impact
./scripts/measure.sh

# Clean up everything
./scripts/teardown.sh
```

## Guided Demo

Run the full demo with narration and pauses between steps:

```bash
./scripts/demo.sh
```

Walks through: baseline (1 pair) → scale to 5 pairs → scale to 10 pairs → slow policy engine simulation.

To capture output for later analysis:

```bash
./scripts/demo.sh 2>&1 | tee demo-output.txt
```

## How It Works

- A Python webhook server runs on a UBI 9 base image. The server code is delivered via ConfigMap — no image build required.
- The server responds to admission review requests with a configurable delay (`WEBHOOK_DELAY_MS` env var), simulating a real policy engine's processing time.
- A configurable percentage of validating requests are randomly rejected (`WEBHOOK_REJECT_PERCENT`), simulating policy enforcement failures.
- `scale-webhooks.sh N` registers N ValidatingWebhookConfigurations + N MutatingWebhookConfigurations, all pointing at the same server. Each registration adds a sequential admission call to every matching API request.
- Webhooks only target the `webhook-perf-test` namespace (via label selector), so they don't affect the rest of the cluster.
- TLS is handled automatically via OpenShift service serving certificates.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `WEBHOOK_DELAY_MS` | `100` | Simulated processing delay per admission request (ms) |
| `WEBHOOK_REJECT_PERCENT` | `5` | Percentage of validating requests to reject per webhook (0-100). With N webhooks, effective rejection rate is 1-(1-rate/100)^N |
| `WEBHOOK_NAME` | `webhook-test` | Identifier in logs and mutation annotations |

Change the delay on a running server:

```bash
oc set env deployment/webhook-server WEBHOOK_DELAY_MS=500 -n webhook-perf-test
```

Disable rejections:

```bash
oc set env deployment/webhook-server WEBHOOK_REJECT_PERCENT=0 -n webhook-perf-test
```

## Performance Queries

See [docs/performance-queries.md](docs/performance-queries.md) for PromQL queries, `oc` commands, and an interpretation guide.

## Tested Versions

See [docs/tested-versions.md](docs/tested-versions.md).

## Repository Structure

```
├── deploy/
│   ├── 00-namespace.yaml               # Namespace with webhook selector label
│   ├── 01-webhook-server.yaml          # ConfigMap (Python), Deployment, Service
│   ├── 02-webhook-config-template.yaml # Template for webhook registrations
│   └── coo-perses/                     # Cluster Observability Operator + Perses
│       ├── 01-coo.yaml                 # COO operator subscription
│       └── 02-coo-uiplugin-perses.yaml # Perses UI plugin
├── scripts/
│   ├── setup.sh                        # Deploy webhook server + dashboard
│   ├── scale-webhooks.sh               # Register N webhook pairs
│   ├── trigger.sh                      # Deploy sample app to fire webhooks
│   ├── measure.sh                      # Query and display latency metrics
│   ├── demo.sh                         # Guided walkthrough
│   └── teardown.sh                     # Clean up all resources
├── dashboards/
│   ├── webhook-perf-persesdashboard.yaml       # Perses dashboard CR
│   ├── webhook-perf-perses-globaldatasource.yaml # Perses datasource CR
│   └── webhook-performance-grafana.json        # Grafana dashboard (alternative)
└── docs/
    ├── performance-queries.md          # Full query reference
    └── tested-versions.md              # Tested OpenShift versions
```
