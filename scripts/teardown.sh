#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="webhook-perf-test"

echo "=== Tearing Down Webhook Performance Tester ==="

echo "Removing webhook configurations..."
oc delete validatingwebhookconfiguration -l app=webhook-perf-test --ignore-not-found
oc delete mutatingwebhookconfiguration -l app=webhook-perf-test --ignore-not-found

echo "Removing webhook server..."
oc delete deployment webhook-server -n "${NAMESPACE}" --ignore-not-found
oc delete service webhook-server -n "${NAMESPACE}" --ignore-not-found
oc delete configmap webhook-server-code -n "${NAMESPACE}" --ignore-not-found
oc delete secret webhook-server-cert -n "${NAMESPACE}" --ignore-not-found

echo "Removing trigger deployments..."
oc delete deployments -n "${NAMESPACE}" -l app --ignore-not-found 2>/dev/null || true

echo ""
echo "=== Teardown Complete ==="
echo ""
echo "The following resources were preserved for reuse:"
echo "  - Namespace: ${NAMESPACE}"
echo "  - Perses dashboard and datasource (if deployed)"
echo ""
echo "To fully remove everything when done:"
echo "  oc delete -f dashboards/webhook-perf-persesdashboard.yaml --ignore-not-found"
echo "  oc delete -f dashboards/webhook-perf-perses-globaldatasource.yaml --ignore-not-found"
echo "  oc delete namespace ${NAMESPACE}"
echo ""
echo "To also remove the Perses UI plugin:"
echo "  oc delete -f deploy/coo-perses/02-coo-uiplugin-perses.yaml --ignore-not-found"
echo ""
echo "To also remove the Cluster Observability Operator:"
echo "  oc delete -f deploy/coo-perses/01-coo.yaml --ignore-not-found"
