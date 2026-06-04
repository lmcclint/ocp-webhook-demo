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

echo "Deleting namespace..."
oc delete namespace "${NAMESPACE}" --ignore-not-found

echo ""
echo "=== Teardown Complete ==="
