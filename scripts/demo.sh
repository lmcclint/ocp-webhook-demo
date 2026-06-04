#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pause() {
    echo ""
    read -r -p "Press Enter to continue..."
    echo ""
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Webhook Performance Impact Demo                       ║"
echo "║       Demonstrating admission webhook latency cascading     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "This demo deploys simulated admission webhooks and measures"
echo "their impact on API server request latency as the number of"
echo "webhooks increases."
pause

# Step 1: Setup
echo "━━━ Step 1: Deploy Webhook Server ━━━"
echo "Deploying a Python-based webhook server that simulates"
echo "processing delay on every admission request."
echo ""
"${SCRIPT_DIR}/setup.sh"
pause

# Step 2: Baseline — 1 webhook pair
echo "━━━ Step 2: Baseline — 1 Validating + 1 Mutating Webhook ━━━"
echo "Registering a single pair of webhooks. Each request to create"
echo "or update a Pod/Deployment in the test namespace will pass"
echo "through both webhooks, each adding 100ms of simulated delay."
echo ""
"${SCRIPT_DIR}/scale-webhooks.sh" 1
pause

echo "Triggering a deployment to measure baseline latency..."
echo ""
"${SCRIPT_DIR}/trigger.sh"
pause

echo "Collecting metrics..."
echo ""
"${SCRIPT_DIR}/measure.sh"
pause

# Step 3: Scale to 5
echo "━━━ Step 3: Scale to 5 Webhook Pairs (10 total) ━━━"
echo "Now registering 5 validating + 5 mutating webhooks."
echo "The same deployment operation will now pass through 10"
echo "sequential admission calls — expect ~5x the latency."
echo ""
"${SCRIPT_DIR}/scale-webhooks.sh" 5
pause

echo "Triggering the same deployment again..."
echo ""
"${SCRIPT_DIR}/trigger.sh"
pause

echo "Collecting metrics..."
echo ""
"${SCRIPT_DIR}/measure.sh"
pause

# Step 4: Scale to 10
echo "━━━ Step 4: Scale to 10 Webhook Pairs (20 total) ━━━"
echo "Now 10 validating + 10 mutating = 20 webhooks in the chain."
echo "Each API call that creates or updates a Pod/Deployment will"
echo "pass through all 20, adding ~2 seconds per operation."
echo ""
"${SCRIPT_DIR}/scale-webhooks.sh" 10
pause

echo "Triggering the deployment..."
echo ""
"${SCRIPT_DIR}/trigger.sh"
pause

echo "Collecting metrics..."
echo ""
"${SCRIPT_DIR}/measure.sh"
pause

# Step 5: Slow policy engine simulation
echo "━━━ Step 5: Simulating a Slow Policy Engine ━━━"
echo "Setting webhook delay to 500ms to simulate a policy engine"
echo "under load (e.g., Kyverno evaluating complex policies)."
echo "With 10 webhook pairs, that's 10 seconds per API call."
echo ""
oc set env deployment/webhook-server WEBHOOK_DELAY_MS=500 -n webhook-perf-test
oc rollout status deployment/webhook-server -n webhook-perf-test --timeout=120s
pause

echo "Triggering the deployment with slow webhooks..."
echo ""
"${SCRIPT_DIR}/trigger.sh"
pause

echo "Final metrics..."
echo ""
"${SCRIPT_DIR}/measure.sh"
pause

# Cleanup
echo "━━━ Cleanup ━━━"
read -r -p "Run teardown to remove all test resources? [Y/n] " answer
case "${answer}" in
    [nN]*)
        echo "Skipping teardown. Run ./scripts/teardown.sh when ready."
        ;;
    *)
        "${SCRIPT_DIR}/teardown.sh"
        ;;
esac

echo ""
echo "Demo complete."
