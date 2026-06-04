#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/../deploy/02-webhook-config-template.yaml"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <count>"
    echo "  Creates <count> validating + <count> mutating webhook configurations."
    echo "  Example: $0 5  →  5 validating + 5 mutating = 10 total webhooks"
    exit 1
fi

COUNT=$1

if ! [[ "${COUNT}" =~ ^[0-9]+$ ]] || [ "${COUNT}" -lt 1 ]; then
    echo "ERROR: count must be a positive integer"
    exit 1
fi

echo "=== Scaling Webhooks ==="

echo "Removing existing webhook-perf-* configurations..."
oc delete validatingwebhookconfiguration -l app=webhook-perf-test --ignore-not-found
oc delete mutatingwebhookconfiguration -l app=webhook-perf-test --ignore-not-found

echo "Creating ${COUNT} validating + ${COUNT} mutating webhook configurations..."

for i in $(seq -w 1 "${COUNT}"); do
    VALIDATE_NAME="webhook-perf-validate-${i}"
    MUTATE_NAME="webhook-perf-mutate-${i}"

    # Extract the validating template (first YAML document) and substitute
    sed -n '1,/^---$/p' "${TEMPLATE_FILE}" | sed '$d' | \
        sed "s/PLACEHOLDER_NAME/${VALIDATE_NAME}/g" | \
        oc apply -f - --overwrite

    # Add the label after creation (since template doesn't have it)
    oc label validatingwebhookconfiguration "${VALIDATE_NAME}" app=webhook-perf-test --overwrite

    # Extract the mutating template (second YAML document) and substitute
    sed -n '/^---$/,$ p' "${TEMPLATE_FILE}" | tail -n +2 | \
        sed "s/PLACEHOLDER_NAME/${MUTATE_NAME}/g" | \
        oc apply -f - --overwrite

    oc label mutatingwebhookconfiguration "${MUTATE_NAME}" app=webhook-perf-test --overwrite

    echo "  Created: ${VALIDATE_NAME}, ${MUTATE_NAME}"
done

echo ""
echo "=== Done ==="
echo "Registered webhooks:"
echo "  Validating: $(oc get validatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "  Mutating:   $(oc get mutatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo ""
echo "Run ./scripts/trigger.sh to fire the webhooks."
