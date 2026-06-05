#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}/../deploy"
NAMESPACE="webhook-perf-test"

echo "=== Deploying Webhook Performance Tester ==="

echo "Checking access requirements..."
PREFLIGHT_FAIL=0

if ! oc auth can-i create namespaces &>/dev/null; then
    echo "  ERROR: Cannot create namespaces"
    PREFLIGHT_FAIL=1
fi

if ! oc auth can-i create validatingwebhookconfigurations &>/dev/null; then
    echo "  ERROR: Cannot create ValidatingWebhookConfigurations (cluster-scoped)"
    PREFLIGHT_FAIL=1
fi

if ! oc auth can-i create mutatingwebhookconfigurations &>/dev/null; then
    echo "  ERROR: Cannot create MutatingWebhookConfigurations (cluster-scoped)"
    PREFLIGHT_FAIL=1
fi

if ! oc auth can-i get routes -n openshift-monitoring &>/dev/null; then
    echo "  WARNING: Cannot read routes in openshift-monitoring — metrics collection will be limited"
fi

if [ "${PREFLIGHT_FAIL}" -eq 1 ]; then
    echo ""
    echo "This toolkit requires cluster-admin access. Log in with:"
    echo "  oc login --token=<token> --server=<api-url>"
    exit 1
fi

echo "  Access checks passed (logged in as: $(oc whoami 2>/dev/null || echo 'unknown'))"
echo ""

echo "Cleaning up any existing webhook configurations..."
oc delete validatingwebhookconfiguration -l app=webhook-perf-test --ignore-not-found 2>/dev/null || true
oc delete mutatingwebhookconfiguration -l app=webhook-perf-test --ignore-not-found 2>/dev/null || true

echo "Creating namespace..."
oc apply -f "${DEPLOY_DIR}/00-namespace.yaml"

echo "Deploying webhook server (ConfigMap + Deployment + Service)..."
oc apply -f "${DEPLOY_DIR}/01-webhook-server.yaml"

DASHBOARD_DIR="${SCRIPT_DIR}/../dashboards"
if ! oc get crd persesdashboards.perses.dev &>/dev/null; then
    echo ""
    echo "  NOTE: COO not installed — Perses dashboard will not be deployed."
    echo "  To install COO and enable Perses:"
    echo "    oc apply -f deploy/coo-perses/01-coo.yaml"
    echo "    oc get csv -n openshift-cluster-observability-operator -w  # wait for Succeeded"
    echo "    oc apply -f deploy/coo-perses/02-coo-uiplugin-perses.yaml"
    echo "  Then re-run setup.sh after the operator is ready."
    echo ""
elif ! oc get uiplugin monitoring -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; then
    echo ""
    echo "  NOTE: COO is installed but Perses UI plugin is not enabled or not ready."
    echo "  To enable it:"
    echo "    oc apply -f deploy/coo-perses/02-coo-uiplugin-perses.yaml"
    echo "  Then re-run setup.sh after the plugin is available."
    echo ""
else
    echo "Deploying Perses Thanos datasource and dashboard..."
    oc apply -f "${DASHBOARD_DIR}/webhook-perf-perses-globaldatasource.yaml"
    oc apply -f "${DASHBOARD_DIR}/webhook-perf-persesdashboard.yaml"
    echo "  Dashboard available in OpenShift console: Observe -> Dashboards (Perses)"
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
