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
