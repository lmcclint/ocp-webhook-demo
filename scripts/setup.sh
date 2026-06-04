#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}/../deploy"
NAMESPACE="webhook-perf-test"

echo "=== Deploying Webhook Performance Tester ==="

echo "Creating namespace..."
oc apply -f "${DEPLOY_DIR}/00-namespace.yaml"

echo "Deploying webhook server (ConfigMap + Deployment + Service)..."
oc apply -f "${DEPLOY_DIR}/01-webhook-server.yaml"

DASHBOARD_DIR="${SCRIPT_DIR}/../dashboards"
if oc api-resources --api-group=perses.dev 2>/dev/null | grep -q PersesDashboard; then
    echo "Deploying Perses dashboard..."
    oc apply -f "${DASHBOARD_DIR}/webhook-perf-perses-globaldatasource.yaml"
    oc apply -f "${DASHBOARD_DIR}/webhook-perf-persesdashboard.yaml"
else
    echo ""
    echo "  NOTE: Perses CRDs not found — dashboard will not be deployed."
    echo "  To install COO and enable Perses:"
    echo "    oc apply -f deploy/coo-perses/01-coo.yaml"
    echo "    oc apply -f deploy/coo-perses/02-coo-uiplugin-perses.yaml"
    echo "  Then re-run setup.sh after the operator is ready."
    echo ""
fi

echo "Waiting for service serving cert..."
for i in $(seq 1 30); do
    if oc get secret webhook-server-cert -n "${NAMESPACE}" &>/dev/null; then
        echo "  TLS cert secret ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Timed out waiting for service serving cert secret."
        exit 1
    fi
    sleep 2
done

echo "Waiting for webhook server pod to be ready..."
oc rollout status deployment/webhook-server -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== Setup Complete ==="
oc get pods -n "${NAMESPACE}"
echo ""
echo "Next steps:"
echo "  1. Register webhooks:  ./scripts/scale-webhooks.sh <count>"
echo "  2. Trigger a rollout:  ./scripts/trigger.sh"
echo "  3. Measure impact:     ./scripts/measure.sh"
