# Webhook Performance Queries

Queries for measuring and diagnosing admission webhook performance on OpenShift. These are the same queries used by `scripts/measure.sh`, documented here for manual use and reference.

## Listing Registered Webhooks

Show all validating and mutating webhooks on the cluster:

```bash
# All validating webhooks
oc get validatingwebhookconfiguration

# All mutating webhooks
oc get mutatingwebhookconfiguration

# Just the webhook-perf-test ones
oc get validatingwebhookconfiguration -l app=webhook-perf-test
oc get mutatingwebhookconfiguration -l app=webhook-perf-test

# Detailed view — shows rules, failure policy, namespace selectors
oc get validatingwebhookconfiguration <name> -o yaml
```

## Prometheus / PromQL Queries

These queries run against the Thanos Querier in `openshift-monitoring`. Access via the OpenShift web console (Observe → Metrics) or the API:

```bash
# Get the route
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
TOKEN=$(oc whoami -t)

# Query example
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${THANOS_HOST}/api/v1/query" \
  --data-urlencode "query=YOUR_QUERY_HERE"
```

### Per-Webhook Admission Latency

The primary metric. Shows how long each webhook takes to process admission requests.

```promql
# Average latency per webhook (last 5 minutes)
sort_desc(
  rate(apiserver_admission_webhook_admission_duration_seconds_sum[5m])
  /
  rate(apiserver_admission_webhook_admission_duration_seconds_count[5m])
)

# P99 latency per webhook
histogram_quantile(0.99,
  rate(apiserver_admission_webhook_admission_duration_seconds_bucket[5m])
)

# P95 latency per webhook
histogram_quantile(0.95,
  rate(apiserver_admission_webhook_admission_duration_seconds_bucket[5m])
)

# Filter to only webhook-perf-test webhooks
sort_desc(
  rate(apiserver_admission_webhook_admission_duration_seconds_sum{name=~"webhook-perf-.*"}[5m])
  /
  rate(apiserver_admission_webhook_admission_duration_seconds_count{name=~"webhook-perf-.*"}[5m])
)
```

### Total Admission Step Duration

How long the entire validating or mutating admission step takes (sum of all webhooks in that step).

```promql
# Average total validating step duration
rate(apiserver_admission_step_admission_duration_seconds_sum{type="validate"}[5m])
/
rate(apiserver_admission_step_admission_duration_seconds_count{type="validate"}[5m])

# Average total mutating step duration
rate(apiserver_admission_step_admission_duration_seconds_sum{type="mutate"}[5m])
/
rate(apiserver_admission_step_admission_duration_seconds_count{type="mutate"}[5m])
```

### Webhook Rejections

Should be 0 for our test webhooks (they always allow). Non-zero on a real cluster indicates a webhook is blocking requests.

```promql
# Total rejections by webhook
sum by (name) (apiserver_admission_webhook_rejection_count)

# Rejection rate (last 5 minutes)
sum by (name) (rate(apiserver_admission_webhook_rejection_count[5m]))
```

### Webhook Call Rate

How often each webhook is being called. Useful for identifying high-traffic webhooks.

```promql
# Calls per second by webhook
sum by (name) (rate(apiserver_admission_webhook_admission_duration_seconds_count[5m]))
```

## oc / kubectl Diagnostic Commands

```bash
# Events related to webhook failures
oc get events --field-selector reason=FailedCreate -A

# Webhook server pod resource usage
oc adm top pods -n webhook-perf-test

# Webhook server logs (see per-request timing)
oc logs deployment/webhook-server -n webhook-perf-test

# Check if any webhooks have failurePolicy: Fail (risky on production)
oc get validatingwebhookconfiguration -o json | \
  jq -r '.items[] | select(.webhooks[]?.failurePolicy == "Fail") | .metadata.name'

oc get mutatingwebhookconfiguration -o json | \
  jq -r '.items[] | select(.webhooks[]?.failurePolicy == "Fail") | .metadata.name'

# Count total webhooks on the cluster
echo "Validating: $(oc get validatingwebhookconfiguration --no-headers | wc -l)"
echo "Mutating: $(oc get mutatingwebhookconfiguration --no-headers | wc -l)"
```

## API Server Audit Logs

When audit logging is enabled, you can correlate admission latency to specific requests:

```bash
# On a master node or via must-gather
grep "admission" /var/log/kube-apiserver/audit.log | \
  jq 'select(.annotations["authorization.k8s.io/decision"] == "allow") |
      {verb, resource: .objectRef.resource, latency: .annotations["apiserver.latency.k8s.io/total"]}'
```

## Interpreting Results

> **Note:** The thresholds below are general guidelines based on common production observations, not official Kubernetes or Red Hat benchmarks. Actual acceptable values will vary depending on cluster size, workload patterns, and SLO requirements.

| Metric | Healthy | Warning | Critical |
|---|---|---|---|
| Per-webhook latency | < 100ms | 100-500ms | > 500ms |
| Total admission overhead | < 200ms | 200ms-1s | > 1s |
| Webhook rejection rate | 0 | < 1/min | > 1/min |
| Webhook count (cluster-wide) | < 10 | 10-20 | > 20 |

**What "good" looks like:**
- Individual webhooks respond in under 100ms
- Total admission overhead is a small fraction of API request time
- No webhooks with `failurePolicy: Fail` unless intentional
- Webhook count is proportional to actual policy needs

**Red flags:**
- A single webhook consistently above 500ms — investigate the policy engine's performance
- Total admission time exceeding 2s — API calls will feel sluggish, rollouts slow down
- Webhook count growing without governance — each team adding their own policy tool
- Webhooks with broad `rules` (matching all resources) when they only need specific ones
