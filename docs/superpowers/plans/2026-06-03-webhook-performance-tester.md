# Webhook Performance Tester Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a toolkit that deploys simulated admission webhooks on OpenShift, with configurable latency and scaling, to measure and demonstrate the performance impact of webhook sprawl.

**Architecture:** Python HTTPS server delivered via ConfigMap on a UBI base image. Shell scripts orchestrate deployment, scaling (N webhook registrations pointing at one server), triggering (sample app rollouts), and metric collection (Prometheus/oc queries). No image builds required.

**Tech Stack:** Python 3.12 (stdlib only), OpenShift service serving certs, Bash, oc CLI, PromQL

---

### Task 1: Namespace Manifest

**Files:**
- Create: `deploy/00-namespace.yaml`

- [ ] **Step 1: Create the namespace manifest**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: webhook-perf-test
  labels:
    webhook-perf-test: "true"
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('deploy/00-namespace.yaml'))"`
Expected: No output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add deploy/00-namespace.yaml
git commit -m "Add namespace manifest with webhook selector label"
```

---

### Task 2: Python Webhook Server

**Files:**
- Create: `deploy/01-webhook-server.yaml`

This is a single YAML manifest with three resources separated by `---`: ConfigMap (Python code), Deployment, and Service.

- [ ] **Step 1: Create the ConfigMap containing the Python server**

The Python server (`server.py`) uses only stdlib. It:
- Reads `WEBHOOK_DELAY_MS` (default 100), `WEBHOOK_NAME` (default "webhook-test"), `TLS_CERT_PATH` (default "/etc/tls/tls.crt"), `TLS_KEY_PATH` (default "/etc/tls/tls.key") from env
- Starts an HTTPS server on port 8443
- Handles POST to `/validate` — sleeps for the configured delay, returns an AdmissionReview with `allowed: true`
- Handles POST to `/mutate` — sleeps for the configured delay, returns an AdmissionReview with a JSON patch adding annotation `webhook-test/processed-by: <webhook-name>`
- Handles GET to `/healthz` — returns 200 (for readiness probe)
- Logs each admission request: timestamp, webhook name, resource kind, namespace, delay ms, total response time ms

```python
import http.server
import ssl
import json
import os
import time
import base64

DELAY_MS = int(os.environ.get("WEBHOOK_DELAY_MS", "100"))
WEBHOOK_NAME = os.environ.get("WEBHOOK_NAME", "webhook-test")
CERT_PATH = os.environ.get("TLS_CERT_PATH", "/etc/tls/tls.crt")
KEY_PATH = os.environ.get("TLS_KEY_PATH", "/etc/tls/tls.key")
PORT = 8443


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        start = time.time()
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)
        review = json.loads(body)

        request = review.get("request", {})
        uid = request.get("uid", "")
        kind = request.get("kind", {}).get("kind", "Unknown")
        namespace = request.get("namespace", "")

        time.sleep(DELAY_MS / 1000.0)

        if self.path == "/validate":
            response = self._validate_response(uid)
        elif self.path == "/mutate":
            response = self._mutate_response(uid)
        else:
            self.send_response(404)
            self.end_headers()
            return

        resp_body = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)

        elapsed = (time.time() - start) * 1000
        print(
            f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} "
            f"webhook={WEBHOOK_NAME} path={self.path} kind={kind} "
            f"namespace={namespace} delay={DELAY_MS}ms "
            f"elapsed={elapsed:.0f}ms"
        )

    def _validate_response(self, uid):
        return {
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": {
                "uid": uid,
                "allowed": True,
            },
        }

    def _mutate_response(self, uid):
        patch = [
            {
                "op": "add",
                "path": "/metadata/annotations/webhook-test~1processed-by",
                "value": WEBHOOK_NAME,
            }
        ]
        patch_bytes = base64.b64encode(json.dumps(patch).encode()).decode()
        return {
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": {
                "uid": uid,
                "allowed": True,
                "patchType": "JSONPatch",
                "patch": patch_bytes,
            },
        }

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", PORT), WebhookHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT_PATH, KEY_PATH)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print(f"Webhook server starting on :{PORT} delay={DELAY_MS}ms name={WEBHOOK_NAME}")
    server.serve_forever()
```

- [ ] **Step 2: Add the Deployment resource below the ConfigMap**

The Deployment mounts the ConfigMap at `/app/server.py` (subPath) and the service serving cert Secret at `/etc/tls/`. It uses the UBI Python 3.12 image with no special security context (compatible with restricted-v2 SCC). The readiness probe hits `/healthz` on the HTTPS port.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-server
  namespace: webhook-perf-test
  labels:
    app: webhook-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: webhook-server
  template:
    metadata:
      labels:
        app: webhook-server
    spec:
      containers:
        - name: webhook-server
          image: registry.access.redhat.com/ubi9/python-312
          command: ["python3", "/app/server.py"]
          ports:
            - containerPort: 8443
              protocol: TCP
          env:
            - name: WEBHOOK_DELAY_MS
              value: "100"
            - name: WEBHOOK_NAME
              value: "webhook-test"
          volumeMounts:
            - name: server-code
              mountPath: /app/server.py
              subPath: server.py
              readOnly: true
            - name: tls-certs
              mountPath: /etc/tls
              readOnly: true
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 3
            periodSeconds: 5
      volumes:
        - name: server-code
          configMap:
            name: webhook-server-code
        - name: tls-certs
          secret:
            secretName: webhook-server-cert
```

- [ ] **Step 3: Add the Service resource with serving cert annotation**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: webhook-server
  namespace: webhook-perf-test
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: webhook-server-cert
spec:
  selector:
    app: webhook-server
  ports:
    - port: 443
      targetPort: 8443
      protocol: TCP
```

- [ ] **Step 4: Assemble the full `deploy/01-webhook-server.yaml`**

Combine all three resources (ConfigMap wrapping the Python code, Deployment, Service) into a single file separated by `---`. The ConfigMap should have:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: webhook-server-code
  namespace: webhook-perf-test
data:
  server.py: |
    # (the full Python script from Step 1, indented under the YAML literal block)
```

Then `---`, then the Deployment from Step 2, then `---`, then the Service from Step 3.

- [ ] **Step 5: Validate YAML syntax**

Run: `python3 -c "import yaml; [doc for doc in yaml.safe_load_all(open('deploy/01-webhook-server.yaml'))]"`
Expected: No output (valid multi-document YAML)

- [ ] **Step 6: Commit**

```bash
git add deploy/01-webhook-server.yaml
git commit -m "Add webhook server: Python code ConfigMap, Deployment, and Service"
```

---

### Task 3: Webhook Configuration Templates

**Files:**
- Create: `deploy/02-webhook-config-template.yaml`

This file contains two YAML document templates (separated by `---`) with `PLACEHOLDER_` prefixed tokens that `scale-webhooks.sh` will substitute with `sed`.

- [ ] **Step 1: Create the template file**

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: PLACEHOLDER_NAME
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
webhooks:
  - name: PLACEHOLDER_NAME.webhook-perf-test.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Ignore
    clientConfig:
      service:
        name: webhook-server
        namespace: webhook-perf-test
        path: /validate
        port: 443
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: Namespaced
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
        scope: Namespaced
    namespaceSelector:
      matchLabels:
        webhook-perf-test: "true"
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: PLACEHOLDER_NAME
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
webhooks:
  - name: PLACEHOLDER_NAME.webhook-perf-test.svc
    admissionReviewVersions: ["v1"]
    sideEffects: NoneOnDryRun
    failurePolicy: Ignore
    reinvocationPolicy: IfNeeded
    clientConfig:
      service:
        name: webhook-server
        namespace: webhook-perf-test
        path: /mutate
        port: 443
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: Namespaced
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
        scope: Namespaced
    namespaceSelector:
      matchLabels:
        webhook-perf-test: "true"
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; [doc for doc in yaml.safe_load_all(open('deploy/02-webhook-config-template.yaml'))]"`
Expected: No output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add deploy/02-webhook-config-template.yaml
git commit -m "Add webhook configuration templates for validating and mutating webhooks"
```

---

### Task 4: setup.sh

**Files:**
- Create: `scripts/setup.sh`

- [ ] **Step 1: Create setup.sh**

```bash
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
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/setup.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/setup.sh
git commit -m "Add setup script for namespace and webhook server deployment"
```

---

### Task 5: scale-webhooks.sh

**Files:**
- Create: `scripts/scale-webhooks.sh`

- [ ] **Step 1: Create scale-webhooks.sh**

```bash
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
        oc apply -l app=webhook-perf-test -f - --overwrite

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
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/scale-webhooks.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/scale-webhooks.sh
git commit -m "Add scale-webhooks script for registering N webhook pairs"
```

---

### Task 6: trigger.sh

**Files:**
- Create: `scripts/trigger.sh`

- [ ] **Step 1: Create trigger.sh**

```bash
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
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/trigger.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/trigger.sh
git commit -m "Add trigger script for deploying sample apps to fire webhooks"
```

---

### Task 7: measure.sh

**Files:**
- Create: `scripts/measure.sh`

- [ ] **Step 1: Create measure.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="webhook-perf-test"

echo "=== Webhook Performance Report ==="
echo ""

# Count registered webhooks
VALIDATE_COUNT=$(oc get validatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
MUTATE_COUNT=$(oc get mutatingwebhookconfiguration -l app=webhook-perf-test --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "Registered webhooks: ${VALIDATE_COUNT} validating, ${MUTATE_COUNT} mutating"

# Get configured delay from deployment env
DELAY=$(oc get deployment webhook-server -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WEBHOOK_DELAY_MS")].value}' 2>/dev/null || echo "unknown")
echo "Configured delay: ${DELAY}ms per webhook"
echo "Expected overhead: $(( (VALIDATE_COUNT + MUTATE_COUNT) * ${DELAY:-0} ))ms total"
echo ""

# List all webhook configurations
echo "--- Validating Webhook Configurations ---"
oc get validatingwebhookconfiguration -l app=webhook-perf-test -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp --no-headers 2>/dev/null || echo "  (none)"
echo ""

echo "--- Mutating Webhook Configurations ---"
oc get mutatingwebhookconfiguration -l app=webhook-perf-test -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp --no-headers 2>/dev/null || echo "  (none)"
echo ""

# Try to get metrics from Prometheus
echo "--- Admission Latency Metrics ---"

THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || true)

if [ -n "${THANOS_HOST}" ]; then
    TOKEN=$(oc whoami -t 2>/dev/null || true)
    if [ -n "${TOKEN}" ]; then
        echo "Querying Prometheus via thanos-querier..."
        echo ""

        # Per-webhook average latency (last 5 minutes)
        echo "Per-webhook average admission latency (last 5m):"
        QUERY='sort_desc(rate(apiserver_admission_webhook_admission_duration_seconds_sum{name=~"webhook-perf-.*"}[5m]) / rate(apiserver_admission_webhook_admission_duration_seconds_count{name=~"webhook-perf-.*"}[5m]))'
        RESULT=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
            "https://${THANOS_HOST}/api/v1/query" \
            --data-urlencode "query=${QUERY}" 2>/dev/null)
        echo "${RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if not results:
        print('  No data yet. Run trigger.sh and wait ~30s for metrics to appear.')
    for r in results:
        name = r['metric'].get('name', 'unknown')
        val = float(r['value'][1])
        print(f'  {name}: {val*1000:.1f}ms avg')
except Exception as e:
    print(f'  Error parsing metrics: {e}')
" 2>/dev/null || echo "  Failed to parse response"
        echo ""

        # Total admission step duration
        echo "Total admission step duration (last 5m avg):"
        for step_type in validate mutate; do
            QUERY="rate(apiserver_admission_step_admission_duration_seconds_sum{type=\"${step_type}\"}[5m]) / rate(apiserver_admission_step_admission_duration_seconds_count{type=\"${step_type}\"}[5m])"
            RESULT=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
                "https://${THANOS_HOST}/api/v1/query" \
                --data-urlencode "query=${QUERY}" 2>/dev/null)
            VAL=$(echo "${RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if results:
        print(f'{float(results[0][\"value\"][1])*1000:.1f}')
    else:
        print('N/A')
except:
    print('N/A')
" 2>/dev/null || echo "N/A")
            echo "  ${step_type}: ${VAL}ms"
        done

        echo ""

        # Webhook rejection count
        echo "Webhook rejections (should be 0):"
        QUERY='sum by (name) (apiserver_admission_webhook_rejection_count{name=~"webhook-perf-.*"})'
        RESULT=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
            "https://${THANOS_HOST}/api/v1/query" \
            --data-urlencode "query=${QUERY}" 2>/dev/null)
        echo "${RESULT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if not results:
        print('  0 rejections (good)')
    for r in results:
        name = r['metric'].get('name', 'unknown')
        val = r['value'][1]
        print(f'  {name}: {val}')
except:
    print('  Unable to query')
" 2>/dev/null || echo "  Failed to parse response"
    else
        echo "  No auth token available. Run 'oc login' first."
    fi
else
    echo "  Thanos querier route not found in openshift-monitoring."
    echo "  Ensure you have cluster-admin or monitoring access."
    echo ""
    echo "  Manual query (run on a master or via 'oc rsh' to prometheus pod):"
    echo "    curl -sk https://localhost:6443/metrics | grep apiserver_admission_webhook_admission_duration"
fi

echo ""

# Pod resource usage
echo "--- Webhook Server Resource Usage ---"
oc adm top pods -n "${NAMESPACE}" 2>/dev/null || echo "  Metrics server not available or no data yet"

echo ""

# Recent events
echo "--- Recent Events (last 10) ---"
oc get events -n "${NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | tail -10 || echo "  No events"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/measure.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/measure.sh
git commit -m "Add measure script for querying webhook admission latency metrics"
```

---

### Task 8: teardown.sh

**Files:**
- Create: `scripts/teardown.sh`

- [ ] **Step 1: Create teardown.sh**

```bash
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
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/teardown.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/teardown.sh
git commit -m "Add teardown script for clean removal of all webhook test resources"
```

---

### Task 9: demo.sh

**Files:**
- Create: `scripts/demo.sh`

- [ ] **Step 1: Create demo.sh**

```bash
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
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/demo.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/demo.sh
git commit -m "Add guided demo script with progressive webhook scaling walkthrough"
```

---

### Task 10: Performance Queries Documentation

**Files:**
- Create: `docs/performance-queries.md`

- [ ] **Step 1: Create performance-queries.md**

```markdown
# Webhook Performance Queries

Queries for measuring and diagnosing admission webhook performance on OpenShift. These are the same queries used by `scripts/measure.sh`, documented here for manual use and reference.

## Listing Registered Webhooks

Show all validating and mutating webhooks on the cluster:

```bash
# All validating webhooks
oc get validatingwebhookconfiguration

# All mutating webhooks
oc get mutatingwebhookconfiguration

# Just the webhook-perf-test ones
oc get validatingwebhookconfiguration -l app=webhook-perf-test
oc get mutatingwebhookconfiguration -l app=webhook-perf-test

# Detailed view — shows rules, failure policy, namespace selectors
oc get validatingwebhookconfiguration <name> -o yaml
```

## Prometheus / PromQL Queries

These queries run against the Thanos Querier in `openshift-monitoring`. Access via the OpenShift web console (Observe → Metrics) or the API:

```bash
# Get the route
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
TOKEN=$(oc whoami -t)

# Query example
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://${THANOS_HOST}/api/v1/query" \
  --data-urlencode "query=YOUR_QUERY_HERE"
```

### Per-Webhook Admission Latency

The primary metric. Shows how long each webhook takes to process admission requests.

```promql
# Average latency per webhook (last 5 minutes)
sort_desc(
  rate(apiserver_admission_webhook_admission_duration_seconds_sum[5m])
  /
  rate(apiserver_admission_webhook_admission_duration_seconds_count[5m])
)

# P99 latency per webhook
histogram_quantile(0.99,
  rate(apiserver_admission_webhook_admission_duration_seconds_bucket[5m])
)

# P95 latency per webhook
histogram_quantile(0.95,
  rate(apiserver_admission_webhook_admission_duration_seconds_bucket[5m])
)

# Filter to only webhook-perf-test webhooks
sort_desc(
  rate(apiserver_admission_webhook_admission_duration_seconds_sum{name=~"webhook-perf-.*"}[5m])
  /
  rate(apiserver_admission_webhook_admission_duration_seconds_count{name=~"webhook-perf-.*"}[5m])
)
```

### Total Admission Step Duration

How long the entire validating or mutating admission step takes (sum of all webhooks in that step).

```promql
# Average total validating step duration
rate(apiserver_admission_step_admission_duration_seconds_sum{type="validate"}[5m])
/
rate(apiserver_admission_step_admission_duration_seconds_count{type="validate"}[5m])

# Average total mutating step duration
rate(apiserver_admission_step_admission_duration_seconds_sum{type="mutate"}[5m])
/
rate(apiserver_admission_step_admission_duration_seconds_count{type="mutate"}[5m])
```

### Webhook Rejections

Should be 0 for our test webhooks (they always allow). Non-zero on a real cluster indicates a webhook is blocking requests.

```promql
# Total rejections by webhook
sum by (name) (apiserver_admission_webhook_rejection_count)

# Rejection rate (last 5 minutes)
sum by (name) (rate(apiserver_admission_webhook_rejection_count[5m]))
```

### Webhook Call Rate

How often each webhook is being called. Useful for identifying high-traffic webhooks.

```promql
# Calls per second by webhook
sum by (name) (rate(apiserver_admission_webhook_admission_duration_seconds_count[5m]))
```

## oc / kubectl Diagnostic Commands

```bash
# Events related to webhook failures
oc get events --field-selector reason=FailedCreate -A

# Webhook server pod resource usage
oc adm top pods -n webhook-perf-test

# Webhook server logs (see per-request timing)
oc logs deployment/webhook-server -n webhook-perf-test

# Check if any webhooks have failurePolicy: Fail (risky on production)
oc get validatingwebhookconfiguration -o json | \
  jq -r '.items[] | select(.webhooks[]?.failurePolicy == "Fail") | .metadata.name'

oc get mutatingwebhookconfiguration -o json | \
  jq -r '.items[] | select(.webhooks[]?.failurePolicy == "Fail") | .metadata.name'

# Count total webhooks on the cluster
echo "Validating: $(oc get validatingwebhookconfiguration --no-headers | wc -l)"
echo "Mutating: $(oc get mutatingwebhookconfiguration --no-headers | wc -l)"
```

## API Server Audit Logs

When audit logging is enabled, you can correlate admission latency to specific requests:

```bash
# On a master node or via must-gather
grep "admission" /var/log/kube-apiserver/audit.log | \
  jq 'select(.annotations["authorization.k8s.io/decision"] == "allow") |
      {verb, resource: .objectRef.resource, latency: .annotations["apiserver.latency.k8s.io/total"]}'
```

## Interpreting Results

| Metric | Healthy | Warning | Critical |
|---|---|---|---|
| Per-webhook latency | < 100ms | 100-500ms | > 500ms |
| Total admission overhead | < 200ms | 200ms-1s | > 1s |
| Webhook rejection rate | 0 | < 1/min | > 1/min |
| Webhook count (cluster-wide) | < 10 | 10-20 | > 20 |

**What "good" looks like:**
- Individual webhooks respond in under 100ms
- Total admission overhead is a small fraction of API request time
- No webhooks with `failurePolicy: Fail` unless intentional
- Webhook count is proportional to actual policy needs

**Red flags:**
- A single webhook consistently above 500ms — investigate the policy engine's performance
- Total admission time exceeding 2s — API calls will feel sluggish, rollouts slow down
- Webhook count growing without governance — each team adding their own policy tool
- Webhooks with broad `rules` (matching all resources) when they only need specific ones
```

- [ ] **Step 2: Commit**

```bash
git add docs/performance-queries.md
git commit -m "Add performance queries documentation with PromQL and oc examples"
```

---

### Task 11: Tested Versions Documentation

**Files:**
- Create: `docs/tested-versions.md`

- [ ] **Step 1: Create tested-versions.md**

```markdown
# Tested OpenShift Versions

| OpenShift Version | Kubernetes Version | Date Tested | Status | Notes |
|---|---|---|---|---|
| — | — | — | — | No clusters tested yet |

## How to Add an Entry

After running the full demo on a cluster:

1. Get the versions:
   ```bash
   oc version
   ```

2. Run the demo:
   ```bash
   ./scripts/demo.sh
   ```

3. Add a row to the table above with any notes about issues encountered.
```

- [ ] **Step 2: Commit**

```bash
git add docs/tested-versions.md
git commit -m "Add tested versions tracking document"
```

---

### Task 12: Grafana Dashboard

**Files:**
- Create: `dashboards/webhook-performance.json`

- [ ] **Step 1: Create the Grafana dashboard JSON**

The dashboard has 4 panels:
1. **Webhook Admission Latency** — time series, per webhook name, using `apiserver_admission_webhook_admission_duration_seconds`
2. **Total Admission Step Duration** — time series, validating vs mutating, using `apiserver_admission_step_admission_duration_seconds`
3. **Webhook Call Rate** — time series, calls/sec per webhook
4. **Admission Overhead %** — gauge/stat showing admission time as percentage of total API request time

```json
{
  "annotations": {
    "list": []
  },
  "description": "Admission webhook performance metrics for webhook-perf-test",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "links": [],
  "panels": [
    {
      "title": "Per-Webhook Admission Latency",
      "description": "Average latency per webhook over time",
      "type": "timeseries",
      "gridPos": { "h": 10, "w": 12, "x": 0, "y": 0 },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "custom": {
            "drawStyle": "line",
            "lineWidth": 2,
            "fillOpacity": 10,
            "pointSize": 5,
            "showPoints": "auto"
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "rate(apiserver_admission_webhook_admission_duration_seconds_sum{name=~\"webhook-perf-.*\"}[5m]) / rate(apiserver_admission_webhook_admission_duration_seconds_count{name=~\"webhook-perf-.*\"}[5m])",
          "legendFormat": "{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Total Admission Step Duration",
      "description": "Combined duration of all webhooks in each admission step",
      "type": "timeseries",
      "gridPos": { "h": 10, "w": 12, "x": 12, "y": 0 },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "custom": {
            "drawStyle": "line",
            "lineWidth": 2,
            "fillOpacity": 10
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "rate(apiserver_admission_step_admission_duration_seconds_sum{type=\"validate\"}[5m]) / rate(apiserver_admission_step_admission_duration_seconds_count{type=\"validate\"}[5m])",
          "legendFormat": "Validating",
          "refId": "A"
        },
        {
          "expr": "rate(apiserver_admission_step_admission_duration_seconds_sum{type=\"mutate\"}[5m]) / rate(apiserver_admission_step_admission_duration_seconds_count{type=\"mutate\"}[5m])",
          "legendFormat": "Mutating",
          "refId": "B"
        }
      ]
    },
    {
      "title": "Webhook Call Rate",
      "description": "Admission webhook calls per second",
      "type": "timeseries",
      "gridPos": { "h": 10, "w": 12, "x": 0, "y": 10 },
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": {
            "drawStyle": "bars",
            "lineWidth": 1,
            "fillOpacity": 50
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "sum by (name) (rate(apiserver_admission_webhook_admission_duration_seconds_count{name=~\"webhook-perf-.*\"}[5m]))",
          "legendFormat": "{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "title": "Webhook Rejection Count",
      "description": "Total admission webhook rejections (should be 0 for test webhooks)",
      "type": "stat",
      "gridPos": { "h": 10, "w": 12, "x": 12, "y": 10 },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 1 },
              { "color": "red", "value": 10 }
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "expr": "sum(apiserver_admission_webhook_rejection_count{name=~\"webhook-perf-.*\"}) or vector(0)",
          "legendFormat": "Rejections",
          "refId": "A"
        }
      ]
    }
  ],
  "schemaVersion": 39,
  "tags": ["webhook", "admission", "performance", "openshift"],
  "templating": { "list": [] },
  "time": { "from": "now-30m", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "Webhook Performance",
  "uid": "webhook-perf-test",
  "version": 1
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboards/webhook-performance.json
git commit -m "Add Grafana dashboard for webhook admission latency visualization"
```

---

### Task 13: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create README.md**

```markdown
# Webhook Performance Tester

A toolkit for measuring and demonstrating the performance impact of admission webhooks on OpenShift clusters.

Deploys a simulated webhook server with configurable latency, registers multiple validating and mutating webhook configurations to demonstrate cascading effects, and provides scripts and queries to measure the impact.

## Quick Start

```bash
# Deploy the webhook server
./scripts/setup.sh

# Register 5 validating + 5 mutating webhooks (100ms delay each)
./scripts/scale-webhooks.sh 5

# Trigger the webhooks by deploying a sample app
./scripts/trigger.sh

# Measure the latency impact
./scripts/measure.sh

# Clean up everything
./scripts/teardown.sh
```

## Guided Demo

Run the full demo with narration and pauses between steps:

```bash
./scripts/demo.sh
```

Walks through: baseline (1 pair) → scale to 5 pairs → scale to 10 pairs → slow policy engine simulation.

## How It Works

- A Python webhook server runs on a UBI 9 base image. The server code is delivered via ConfigMap — no image build required.
- The server responds to admission review requests with a configurable delay (`WEBHOOK_DELAY_MS` env var), simulating a real policy engine's processing time.
- `scale-webhooks.sh N` registers N ValidatingWebhookConfigurations + N MutatingWebhookConfigurations, all pointing at the same server. Each registration adds a sequential admission call to every matching API request.
- Webhooks only target the `webhook-perf-test` namespace (via label selector), so they don't affect the rest of the cluster.
- TLS is handled automatically via OpenShift service serving certificates.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `WEBHOOK_DELAY_MS` | `100` | Simulated processing delay per admission request (ms) |
| `WEBHOOK_NAME` | `webhook-test` | Identifier in logs and mutation annotations |

Change the delay on a running server:

```bash
oc set env deployment/webhook-server WEBHOOK_DELAY_MS=500 -n webhook-perf-test
```

## Performance Queries

See [docs/performance-queries.md](docs/performance-queries.md) for PromQL queries, `oc` commands, and an interpretation guide.

A pre-built Grafana dashboard is available at [dashboards/webhook-performance.json](dashboards/webhook-performance.json).

## Tested Versions

See [docs/tested-versions.md](docs/tested-versions.md).

## Repository Structure

```
├── deploy/                         # Kubernetes/OpenShift manifests
│   ├── 00-namespace.yaml           # Namespace with webhook selector label
│   ├── 01-webhook-server.yaml      # ConfigMap (Python), Deployment, Service
│   └── 02-webhook-config-template.yaml  # Template for webhook registrations
├── scripts/                        # Orchestration scripts
│   ├── setup.sh                    # Deploy the webhook server
│   ├── scale-webhooks.sh           # Register N webhook pairs
│   ├── trigger.sh                  # Deploy sample app to fire webhooks
│   ├── measure.sh                  # Query and display latency metrics
│   ├── demo.sh                     # Guided walkthrough
│   └── teardown.sh                 # Clean up all resources
├── dashboards/
│   └── webhook-performance.json    # Grafana dashboard
└── docs/
    ├── performance-queries.md      # Full query reference
    └── tested-versions.md          # Tested OpenShift versions
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Add README with quick start, configuration, and project overview"
```

---

### Task 14: CLAUDE.md

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Create CLAUDE.md**

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Webhook performance testing toolkit for OpenShift. Deploys simulated admission webhooks with configurable latency to measure and demonstrate the cascading performance impact of webhook sprawl. No image builds — Python server code is delivered via ConfigMap onto a UBI base image.

## Architecture

- `deploy/` — Kubernetes/OpenShift YAML manifests (namespace, webhook server ConfigMap+Deployment+Service, webhook config templates)
- `scripts/` — Bash scripts for setup, scaling, triggering, measurement, demo, and teardown
- `dashboards/` — Grafana dashboard JSON
- `docs/` — Performance query reference and tested version tracking

The webhook server is a single Python script (`deploy/01-webhook-server.yaml` ConfigMap) using only stdlib (http.server, ssl, json). It handles `/validate`, `/mutate`, and `/healthz` endpoints.

Scaling works by registering N ValidatingWebhookConfiguration + N MutatingWebhookConfiguration resources, all pointing at the same server pod. The `scale-webhooks.sh` script generates these from `deploy/02-webhook-config-template.yaml` using sed substitution.

## Key Conventions

- All scripts use `#!/usr/bin/env bash` with `set -euo pipefail`
- Scripts reference the deploy directory relative to their own location via `SCRIPT_DIR`
- Namespace is `webhook-perf-test` with label `webhook-perf-test: "true"` for webhook selectors
- Webhook configurations use the `app=webhook-perf-test` label for bulk operations
- TLS via OpenShift service serving certificates (annotation-driven, auto-generated)
- The Python server has zero external dependencies — stdlib only
- Target platform is OpenShift; uses `oc` CLI throughout (not `kubectl`)

## Testing

No automated test suite — this is a deployment toolkit. Testing is done by running on an OpenShift cluster:

```bash
./scripts/setup.sh
./scripts/scale-webhooks.sh 1
./scripts/trigger.sh
./scripts/measure.sh
./scripts/teardown.sh
```

## Common Tasks

```bash
# Change webhook delay on a running server
oc set env deployment/webhook-server WEBHOOK_DELAY_MS=500 -n webhook-perf-test

# Check webhook server logs
oc logs deployment/webhook-server -n webhook-perf-test

# List all webhook-perf-test webhook configs
oc get validatingwebhookconfiguration -l app=webhook-perf-test
oc get mutatingwebhookconfiguration -l app=webhook-perf-test
```
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Add CLAUDE.md with project guidance for Claude Code"
```

---

Plan complete and saved to `docs/superpowers/plans/2026-06-03-webhook-performance-tester.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?