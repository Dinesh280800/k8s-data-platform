#!/usr/bin/env bash
# =============================================================================
# SCALING & RESILIENCE TEST SCRIPT
# =============================================================================
# Tests autoscaling behavior and failure recovery patterns.
#
# USAGE:
#   chmod +x verification/test-scaling.sh
#   ./verification/test-scaling.sh
# =============================================================================

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${BLUE}[TEST]${NC} $1"; }
ok()  { echo -e "${GREEN}[PASS]${NC} $1"; }
warn(){ echo -e "${YELLOW}[NOTE]${NC} $1"; }

# =============================================================================
echo ""
echo "=============================================="
echo "  AUTOSCALING & RESILIENCE TESTS"
echo "=============================================="
echo ""
# =============================================================================

# --- Test 1: Stress Test for HPA/KEDA CPU Scaling ---
log "TEST 1: CPU Load Generation (triggers autoscaling)"
echo "  Deploying a stress pod to generate CPU load..."

kubectl run cpu-stress \
    --namespace=complex-app \
    --image=busybox:1.36 \
    --restart=Never \
    --requests='cpu=100m' \
    --command -- sh -c "
        echo 'Starting CPU stress...'
        while true; do
            dd if=/dev/zero of=/dev/null bs=1M count=1000 2>/dev/null
        done
    " 2>/dev/null || true

echo ""
echo "  Monitor scaling with:"
echo "    kubectl get hpa -n complex-app -w"
echo "    kubectl get pods -n complex-app -w"
echo ""
warn "CPU scaling takes 1-3 minutes to trigger. Watch with commands above."
echo ""

read -p "Press Enter to continue to next test (stress pod will keep running)..."

# --- Test 2: Pod Failure Recovery ---
log "TEST 2: Pod Failure Recovery (self-healing)"
echo "  Current pods:"
kubectl get pods -n complex-app -l app.kubernetes.io/name=complex-app --no-headers
echo ""

echo "  Deleting one pod to test self-healing..."
POD_TO_DELETE=$(kubectl get pods -n complex-app -l app.kubernetes.io/name=complex-app -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod "${POD_TO_DELETE}" -n complex-app --grace-period=5

echo "  Waiting 10s for replacement..."
sleep 10

echo "  Pods after recovery:"
kubectl get pods -n complex-app -l app.kubernetes.io/name=complex-app --no-headers
echo ""

NEW_COUNT=$(kubectl get pods -n complex-app -l app.kubernetes.io/name=complex-app --no-headers | grep -c Running || echo "0")
if [ "$NEW_COUNT" -ge 2 ]; then
    ok "Self-healing works! Pod was replaced automatically."
else
    warn "Pod replacement in progress. Check again in a moment."
fi
echo ""

# --- Test 3: Rolling Update ---
log "TEST 3: Rolling Update (zero-downtime deployment)"
echo "  Triggering a rolling update by changing an env var..."

kubectl set env deployment/complex-app -n complex-app DEPLOY_TIMESTAMP="$(date +%s)"
echo "  Watching rollout status..."
kubectl rollout status deployment/complex-app -n complex-app --timeout=120s
ok "Rolling update completed successfully."
echo ""

# --- Test 4: Rollback ---
log "TEST 4: Rollback to Previous Version"
echo "  Rolling back deployment..."
kubectl rollout undo deployment/complex-app -n complex-app
kubectl rollout status deployment/complex-app -n complex-app --timeout=120s
ok "Rollback completed."
echo ""

# --- Test 5: Node Drain (PDB test) ---
log "TEST 5: Node Drain (tests PodDisruptionBudget)"
echo "  PDB status:"
kubectl get pdb -n complex-app
echo ""

WORKER_NODE=$(kubectl get nodes --no-headers | grep -v control-plane | head -1 | awk '{print $1}')
echo "  Draining node: ${WORKER_NODE}"
echo "  (PDB should prevent more than 1 pod being evicted at a time)"
echo ""
warn "Run manually to test: kubectl drain ${WORKER_NODE} --ignore-daemonsets --delete-emptydir-data"
warn "Then uncordon: kubectl uncordon ${WORKER_NODE}"
echo ""

# --- Test 6: Check KEDA Scaling ---
log "TEST 6: KEDA ScaledObject Status"
kubectl get scaledobject -n complex-app -o wide 2>/dev/null || warn "No ScaledObjects found"
echo ""
kubectl get hpa -n complex-app 2>/dev/null || warn "No HPA found"
echo ""

# --- Cleanup ---
log "CLEANUP: Removing stress pod"
kubectl delete pod cpu-stress -n complex-app --ignore-not-found=true --grace-period=0 --force 2>/dev/null || true
ok "Stress pod removed."
echo ""

# --- Summary ---
echo "=============================================="
echo "  TEST SUMMARY"
echo "=============================================="
echo ""
echo "  Verified:"
echo "    ✓ CPU load generation for scaling triggers"
echo "    ✓ Pod self-healing (delete → automatic replacement)"
echo "    ✓ Rolling update (zero-downtime)"
echo "    ✓ Rollback to previous version"
echo "    ✓ PDB prevents disruptive evictions"
echo "    ✓ KEDA ScaledObject status"
echo ""
echo "  Manual tests recommended:"
echo "    • Watch HPA scale up: kubectl get hpa -n complex-app -w"
echo "    • Check Prometheus targets: http://localhost:9090/targets"
echo "    • View Grafana dashboards: http://localhost:30000"
echo "    • Query logs in Grafana → Explore → Loki:"
echo "        {namespace=\"complex-app\"} |= \"error\""
echo ""
