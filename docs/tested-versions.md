# Tested OpenShift Versions

| OpenShift Version | Kubernetes Version | Date Tested | Status | Notes |
|---|---|---|---|---|
| 4.18 | 1.31 | 2026-06-04 | Tested | Full demo + Perses dashboard |
| 4.20 | 1.33 | 2026-06-04 | Tested | Full demo + Perses dashboard |

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
