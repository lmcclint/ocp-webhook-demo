#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="webhook-perf-test"

echo "=== Webhook Performance Report ==="
echo ""

# Count registered webhooks
VALIDATE_COUNT=$(oc get validatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
MUTATE_COUNT=$(oc get mutatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "Registered webhooks: ${VALIDATE_COUNT} validating, ${MUTATE_COUNT} mutating"

# Get configured delay from deployment env
DELAY=$(oc get deployment webhook-server -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WEBHOOK_DELAY_MS")].value}' 2>/dev/null || echo "unknown")
echo "Configured delay: ${DELAY}ms per webhook"
echo "Expected overhead: $(( (VALIDATE_COUNT + MUTATE_COUNT) * ${DELAY:-0} ))ms total"
echo ""

# List all webhook configurations
echo "--- Validating Webhook Configurations ---"
oc get validatingwebhookconfiguration -l app=webhook-perf-test -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp --no-headers 2>/dev/null || echo "  (none)"
echo ""

echo "--- Mutating Webhook Configurations ---"
oc get mutatingwebhookconfiguration -l app=webhook-perf-test -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp --no-headers 2>/dev/null || echo "  (none)"
echo ""

# Try to get metrics from Prometheus
echo "--- Admission Latency Metrics ---"

THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || true)

if [ -n "${THANOS_HOST}" ]; then
    TOKEN=$(oc whoami -t 2>/dev/null || true)
    if [ -n "${TOKEN}" ]; then
        echo "Querying Prometheus via thanos-querier..."
        echo ""

        # Per-webhook average latency (last 5 minutes)
        echo "Per-webhook average admission latency (last 5m):"
        QUERY='sort_desc(rate(apiserver_admission_webhook_admission_duration_seconds_sum{name=~"webhook-perf-.*"}[5m]) / rate(apiserver_admission_webhook_admission_duration_seconds_count{name=~"webhook-perf-.*"}[5m]))'
        RESULT=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
            "https://${THANOS_HOST}/api/v1/query" \
            --data-urlencode "query=${QUERY}" 2>/dev/null)
        echo "${RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if not results:
        print('  No data yet. Run trigger.sh and wait ~30s for metrics to appear.')
    for r in results:
        name = r['metric'].get('name', 'unknown')
        val = float(r['value'][1])
        print(f'  {name}: {val*1000:.1f}ms avg')
except Exception as e:
    print(f'  Error parsing metrics: {e}')
" 2>/dev/null || echo "  Failed to parse response"
        echo ""

        # Total admission step duration
        echo "Total admission step duration (last 5m avg):"
        for step_type in validate mutate; do
            QUERY="rate(apiserver_admission_step_admission_duration_seconds_sum{type=\"${step_type}\"}[5m]) / rate(apiserver_admission_step_admission_duration_seconds_count{type=\"${step_type}\"}[5m])"
            RESULT=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
                "https://${THANOS_HOST}/api/v1/query" \
                --data-urlencode "query=${QUERY}" 2>/dev/null)
            VAL=$(echo "${RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if results:
        print(f'{float(results[0][\"value\"][1])*1000:.1f}')
    else:
        print('N/A')
except:
    print('N/A')
" 2>/dev/null || echo "N/A")
            echo "  ${step_type}: ${VAL}ms"
        done

        echo ""

        # Webhook rejection count
        echo "Webhook rejections (should be 0):"
        QUERY='sum by (name) (apiserver_admission_webhook_rejection_count{name=~"webhook-perf-.*"})'
        RESULT=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
            "https://${THANOS_HOST}/api/v1/query" \
            --data-urlencode "query=${QUERY}" 2>/dev/null)
        echo "${RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if not results:
        print('  0 rejections (good)')
    for r in results:
        name = r['metric'].get('name', 'unknown')
        val = r['value'][1]
        print(f'  {name}: {val}')
except:
    print('  Unable to query')
" 2>/dev/null || echo "  Failed to parse response"
    else
        echo "  No auth token available. Run 'oc login' first."
    fi
else
    echo "  Thanos querier route not found in openshift-monitoring."
    echo "  Ensure you have cluster-admin or monitoring access."
    echo ""
    echo "  Manual query (run on a master or via 'oc rsh' to prometheus pod):"
    echo "    curl -sk https://localhost:6443/metrics | grep apiserver_admission_webhook_admission_duration"
fi

echo ""

# Pod resource usage
echo "--- Webhook Server Resource Usage ---"
oc adm top pods -n "${NAMESPACE}" 2>/dev/null || echo "  Metrics server not available or no data yet"

echo ""

# Recent events
echo "--- Recent Events (last 10) ---"
oc get events -n "${NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | tail -10 || echo "  No events"
