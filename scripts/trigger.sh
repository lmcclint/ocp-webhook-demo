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

    RETRIES=0
    MAX_RETRIES=10
    if oc get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        while ! oc rollout restart deployment/"${DEPLOY_NAME}" -n "${NAMESPACE}" 2>/dev/null; do
            RETRIES=$((RETRIES + 1))
            if [ "${RETRIES}" -ge "${MAX_RETRIES}" ]; then
                echo "  ${DEPLOY_NAME}: gave up after ${MAX_RETRIES} webhook rejections"
                break
            fi
            echo "  Webhook rejected request, retrying... (${RETRIES}/${MAX_RETRIES})"
        done
        oc rollout status deployment/"${DEPLOY_NAME}" -n "${NAMESPACE}" --timeout=120s
    else
        while ! oc create deployment "${DEPLOY_NAME}" --image="${IMAGE}" -n "${NAMESPACE}" 2>/dev/null; do
            RETRIES=$((RETRIES + 1))
            if [ "${RETRIES}" -ge "${MAX_RETRIES}" ]; then
                echo "  ${DEPLOY_NAME}: gave up after ${MAX_RETRIES} webhook rejections"
                break
            fi
            echo "  Webhook rejected request, retrying... (${RETRIES}/${MAX_RETRIES})"
        done
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

echo "Mutating webhook annotations on pods:"
echo "  (webhook-test/processed-by is added by our mutating webhook)"
echo ""
oc get pods -n "${NAMESPACE}" -l app=trigger-app-1 -o json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for pod in data.get('items', []):
        name = pod['metadata']['name']
        annotations = pod['metadata'].get('annotations', {})
        webhook_ann = {k: v for k, v in annotations.items() if 'webhook' in k.lower()}
        other_count = len(annotations) - len(webhook_ann)
        print(f'  {name}:')
        if webhook_ann:
            for k, v in webhook_ann.items():
                print(f'    * {k}: {v}')
        else:
            print(f'    (no webhook annotations)')
        print(f'    + {other_count} other annotations (scc, ovn, cni, etc.)')
except Exception as e:
    print(f'  Error: {e}')
" 2>/dev/null || true
echo ""

VALIDATE_COUNT=$(oc get validatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
MUTATE_COUNT=$(oc get mutatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "Active webhooks: ${VALIDATE_COUNT} validating, ${MUTATE_COUNT} mutating"
