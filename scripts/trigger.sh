#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="webhook-perf-test"
IMAGE="registry.access.redhat.com/ubi9/pause"
COUNT=1
LOOP=false
INTERVAL=5

while [[ $# -gt 0 ]]; do
    case $1 in
        --count)
            COUNT="$2"
            shift 2
            ;;
        --loop)
            LOOP=true
            shift
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--count N] [--loop] [--interval SECONDS]"
            echo "  --count N        Deploy N sample apps per round (default: 1)"
            echo "  --loop           Continuously trigger webhooks (Ctrl-C to stop)"
            echo "  --interval SECS  Seconds between rounds in loop mode (default: 5)"
            exit 1
            ;;
    esac
done

trigger_round() {
    local ROUND_NUM=$1
    local TOTAL_START TOTAL_END TOTAL_MS

    if [ "${LOOP}" = true ]; then
        echo "--- Round ${ROUND_NUM} ($(date +%H:%M:%S)) ---"
    else
        echo "=== Triggering Webhooks ==="
    fi
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

    echo "  Total: ${TOTAL_MS}ms for ${COUNT} deployment(s)"
}

if [ "${LOOP}" = true ]; then
    echo "=== Webhook Load Generator ==="
    echo "Triggering ${COUNT} deployment(s) every ${INTERVAL}s (Ctrl-C to stop)"
    echo ""

    ROUND=0
    trap 'echo ""; echo "Stopped after ${ROUND} rounds."; exit 0' INT

    while true; do
        ROUND=$((ROUND + 1))
        trigger_round "${ROUND}"
        echo "  Next round in ${INTERVAL}s..."
        echo ""
        sleep "${INTERVAL}"
    done
else
    trigger_round 1
    echo ""

    echo "--- Mutation Check ---"
    echo "The mutating webhook adds: webhook-test/processed-by: webhook-test"
    echo ""
    oc get pods -n "${NAMESPACE}" --sort-by=.metadata.creationTimestamp -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
pods = data.get('items', [])
if not pods:
    print('  No pods found')
    sys.exit(0)
latest = pods[-1]
name = latest['metadata']['name']
annotations = latest['metadata'].get('annotations', {})
webhook_val = annotations.get('webhook-test/processed-by')
other_count = len(annotations) - (1 if webhook_val else 0)
print(f'  Pod: {name}')
if webhook_val:
    print(f'  Mutation:  webhook-test/processed-by = {webhook_val}')
else:
    print(f'  Mutation:  NOT FOUND — mutating webhook may not have fired')
print(f'  Other annotations: {other_count} (scc, ovn, cni, etc.)')
" 2>/dev/null || true
    echo ""

    VALIDATE_COUNT=$(oc get validatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
    MUTATE_COUNT=$(oc get mutatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "Active webhooks: ${VALIDATE_COUNT} validating, ${MUTATE_COUNT} mutating"
fi
