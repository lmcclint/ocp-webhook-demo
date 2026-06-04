#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="webhook-perf-test"
IMAGE="registry.access.redhat.com/ubi9/pause"
COUNT=1

while [[ $# -gt 0 ]]; do
    case $1 in
        --count)
            COUNT="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--count N]"
            echo "  Deploys N sample apps to trigger webhooks (default: 1)"
            exit 1
            ;;
    esac
done

echo "=== Triggering Webhooks ==="
echo "Creating/restarting ${COUNT} deployment(s) in ${NAMESPACE}..."
echo ""

TOTAL_START=$(date +%s%N)

for i in $(seq 1 "${COUNT}"); do
    DEPLOY_NAME="trigger-app-${i}"
    START=$(date +%s%N)

    if oc get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        oc rollout restart deployment/"${DEPLOY_NAME}" -n "${NAMESPACE}"
        oc rollout status deployment/"${DEPLOY_NAME}" -n "${NAMESPACE}" --timeout=120s
    else
        oc create deployment "${DEPLOY_NAME}" \
            --image="${IMAGE}" \
            -n "${NAMESPACE}" 2>/dev/null || true
        oc rollout status deployment/"${DEPLOY_NAME}" -n "${NAMESPACE}" --timeout=120s
    fi

    END=$(date +%s%N)
    ELAPSED_MS=$(( (END - START) / 1000000 ))
    echo "  ${DEPLOY_NAME}: ${ELAPSED_MS}ms"
done

TOTAL_END=$(date +%s%N)
TOTAL_MS=$(( (TOTAL_END - TOTAL_START) / 1000000 ))

echo ""
echo "=== Results ==="
echo "Total time: ${TOTAL_MS}ms for ${COUNT} deployment(s)"
echo ""

echo "Checking mutating webhook annotations on pods..."
oc get pods -n "${NAMESPACE}" -l app=trigger-app-1 -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations}{"\n"}{end}' 2>/dev/null || true
echo ""

VALIDATE_COUNT=$(oc get validatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
MUTATE_COUNT=$(oc get mutatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "Active webhooks: ${VALIDATE_COUNT} validating, ${MUTATE_COUNT} mutating"
