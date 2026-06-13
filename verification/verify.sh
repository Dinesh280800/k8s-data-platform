#!/usr/bin/env bash
# =============================================================================
# VERIFICATION SCRIPT - Validate the full stack deployment
# =============================================================================
# Run this after bootstrap.sh to verify everything is working correctly.
#
# USAGE:
#   chmod +x verification/verify.sh
#   ./verification/verify.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

check() {
    local description="$1"
    shift
    if eval "$@" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $description"
        ((PASS++))
    else
        echo -e "  ${RED}✗${NC} $description"
        ((FAIL++))
    fi
}

section() {
    echo ""
    echo -e "${BLUE}━━━ $1 ━━━${NC}"
}

# =============================================================================
section "1. CLUSTER HEALTH"
# =============================================================================

check "Cluster is reachable" "kubectl cluster-info"
check "All nodes are Ready" "[ \$(kubectl get nodes --no-headers | grep -c ' Ready') -ge 4 ]"
check "Control plane node exists" "kubectl get nodes -l node-role.kubernetes.io/control-plane"
check "Worker nodes exist (3)" "[ \$(kubectl get nodes --no-headers | grep -vc control-plane) -ge 3 ]"
check "CoreDNS is running" "kubectl get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running"
check "metrics-server is running" "kubectl get pods -n kube-system -l k8s-app=metrics-server --field-selector=status.phase=Running"

# =============================================================================
section "2. CORE APPLICATION"
# =============================================================================

check "Namespace 'complex-app' exists" "kubectl get namespace complex-app"
check "ConfigMap 'app-config' exists" "kubectl get configmap app-config -n complex-app"
check "Secret 'app-secrets' exists" "kubectl get secret app-secrets -n complex-app"
check "Deployment is available" "kubectl get deployment complex-app -n complex-app -o jsonpath='{.status.availableReplicas}' | grep -E '^[2-9]|^[0-9]{2,}'"
check "All pods are Running" "[ \$(kubectl get pods -n complex-app -l app.kubernetes.io/name=complex-app --field-selector=status.phase=Running --no-headers | wc -l) -ge 2 ]"
check "Service exists" "kubectl get service complex-app-service -n complex-app"
check "Ingress configured" "kubectl get ingress complex-app-ingress -n complex-app"
check "PDB exists" "kubectl get pdb complex-app-pdb -n complex-app"
check "Pods spread across nodes" "[ \$(kubectl get pods -n complex-app -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l) -ge 2 ]"

# =============================================================================
section "3. INGRESS CONTROLLER"
# =============================================================================

check "Ingress controller running" "kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --field-selector=status.phase=Running"
check "Ingress class 'nginx' exists" "kubectl get ingressclass nginx"

# =============================================================================
section "4. MONITORING STACK"
# =============================================================================

check "Monitoring namespace exists" "kubectl get namespace monitoring"
check "Prometheus is running" "kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running"
check "Grafana is running" "kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running"
check "Alertmanager is running" "kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --field-selector=status.phase=Running"
check "Node Exporter DaemonSet running" "kubectl get daemonset -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter"
check "kube-state-metrics running" "kubectl get pods -n monitoring -l app.kubernetes.io/name=kube-state-metrics --field-selector=status.phase=Running"
check "PrometheusRule 'app-alerts' exists" "kubectl get prometheusrule app-alerts -n monitoring"
check "ServiceMonitor exists" "kubectl get servicemonitor complex-app-monitor -n monitoring"
check "Loki is running" "kubectl get pods -n monitoring -l app=loki --field-selector=status.phase=Running"
check "Promtail DaemonSet running" "kubectl get daemonset -n monitoring -l app.kubernetes.io/name=promtail"

# =============================================================================
section "5. KEDA AUTOSCALING"
# =============================================================================

check "KEDA namespace exists" "kubectl get namespace keda"
check "KEDA operator running" "kubectl get pods -n keda -l app=keda-operator --field-selector=status.phase=Running"
check "ScaledObject exists" "kubectl get scaledobject -n complex-app complex-app-scaledobject"
check "KEDA metrics server running" "kubectl get pods -n keda -l app=keda-operator-metrics-apiserver --field-selector=status.phase=Running"

# =============================================================================
section "6. RESOURCE METRICS"
# =============================================================================

echo -e "  ${YELLOW}(Waiting 30s for metrics to populate...)${NC}"
sleep 5  # Brief wait; full metrics take ~60s

check "Node metrics available" "kubectl top nodes 2>/dev/null"
check "Pod metrics available" "kubectl top pods -n complex-app 2>/dev/null"

# =============================================================================
section "RESULTS"
# =============================================================================

echo ""
echo -e "  ${GREEN}Passed: ${PASS}${NC}  |  ${RED}Failed: ${FAIL}${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All checks passed! Stack is fully operational.${NC}"
else
    echo -e "${YELLOW}Some checks failed. Review the output above.${NC}"
    echo ""
    echo "Troubleshooting tips:"
    echo "  - Wait a few minutes and re-run (some components need time to initialize)"
    echo "  - Check pod logs: kubectl logs -n <namespace> <pod-name>"
    echo "  - Describe failing pods: kubectl describe pod -n <namespace> <pod-name>"
    echo "  - Check events: kubectl get events -n <namespace> --sort-by='.lastTimestamp'"
fi

echo ""
exit $FAIL
