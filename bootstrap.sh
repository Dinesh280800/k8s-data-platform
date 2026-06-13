#!/usr/bin/env bash
# =============================================================================
# BOOTSTRAP SCRIPT - Full Kubernetes Stack Setup on Kind
# =============================================================================
# This script automates the complete setup:
#   Phase 1: Prerequisites check + Kind cluster creation
#   Phase 2: Core application deployment
#   Phase 3: Monitoring stack (Prometheus, Grafana, Loki)
#   Phase 4: KEDA autoscaling
#
# USAGE:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh              # Full setup (all phases)
#   ./bootstrap.sh --phase 1   # Only run phase 1
#   ./bootstrap.sh --phase 2   # Only run phase 2
#   ./bootstrap.sh --destroy    # Tear down everything
#
# PREREQUISITES:
#   - Docker or Podman running
#   - kind, kubectl, helm installed
#   - ~8GB RAM available for the cluster
# =============================================================================

set -euo pipefail

# --- Configuration ---
CLUSTER_NAME="complex-cluster"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE="${1:-all}"

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# PHASE 0: Prerequisites Check
# =============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=()

    # Check Docker or Podman
    # Prefer a running engine: check if Docker daemon is reachable, otherwise try Podman
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        log_ok "Docker found (daemon running): $(docker --version)"
    elif command -v podman &> /dev/null && podman info &> /dev/null; then
        log_ok "Podman found (machine running): $(podman --version)"
        export KIND_EXPERIMENTAL_PROVIDER=podman
    elif command -v docker &> /dev/null; then
        log_error "Docker CLI found but daemon is NOT running. Start Docker Desktop or use Podman."
        missing+=("running container runtime")
    elif command -v podman &> /dev/null; then
        log_error "Podman CLI found but machine is NOT running. Run: podman machine start"
        missing+=("running container runtime")
    else
        missing+=("docker or podman")
    fi

    # Check kind
    if command -v kind &> /dev/null; then
        log_ok "kind found: $(kind version)"
    else
        missing+=("kind")
    fi

    # Check kubectl
    if command -v kubectl &> /dev/null; then
        log_ok "kubectl found: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    else
        missing+=("kubectl")
    fi

    # Check helm
    if command -v helm &> /dev/null; then
        log_ok "helm found: $(helm version --short)"
    else
        missing+=("helm")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing prerequisites: ${missing[*]}"
        echo ""
        echo "Install missing tools:"
        echo "  Docker:  https://docs.docker.com/get-docker/"
        echo "  Podman:  brew install podman (macOS) or https://podman.io/getting-started/"
        echo "  kind:    brew install kind (macOS) or https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
        echo "  kubectl: brew install kubectl (macOS) or https://kubernetes.io/docs/tasks/tools/"
        echo "  helm:    brew install helm (macOS) or https://helm.sh/docs/intro/install/"
        echo ""
        echo "Quick install (macOS with Homebrew):"
        echo "  brew install kind kubectl helm"
        exit 1
    fi

    log_ok "All prerequisites satisfied!"
    echo ""
}

# =============================================================================
# PHASE 1: Create Kind Cluster
# =============================================================================
create_cluster() {
    log_info "=== PHASE 1: Creating Kind multi-node cluster ==="
    
    # Check if cluster already exists
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_warn "Cluster '${CLUSTER_NAME}' already exists."
        read -p "Delete and recreate? (y/N): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kind delete cluster --name "${CLUSTER_NAME}"
        else
            log_info "Using existing cluster."
            kubectl cluster-info --context "kind-${CLUSTER_NAME}"
            return 0
        fi
    fi

    # Create the cluster
    log_info "Creating cluster '${CLUSTER_NAME}' with 1 control-plane + 3 workers..."
    kind create cluster \
        --name "${CLUSTER_NAME}" \
        --config "${SCRIPT_DIR}/kind/cluster-config.yaml" \
        --wait 120s

    # Verify cluster
    log_info "Verifying cluster health..."
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
    kubectl get nodes -o wide
    
    # Wait for all nodes to be Ready
    log_info "Waiting for all nodes to be Ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    log_ok "Cluster created successfully! Nodes:"
    kubectl get nodes
    echo ""
}

# =============================================================================
# PHASE 1.5: Install Ingress Controller (nginx)
# =============================================================================
install_ingress_controller() {
    log_info "Installing NGINX Ingress Controller..."
    
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

    log_info "Waiting for Ingress Controller to be ready..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=120s

    log_ok "Ingress Controller installed!"
    echo ""
}

# =============================================================================
# PHASE 1.6: Install metrics-server (required for HPA)
# =============================================================================
install_metrics_server() {
    log_info "Installing metrics-server..."
    
    # Install metrics-server with modifications for kind (insecure TLS)
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

    # Patch metrics-server for kind (kind nodes use self-signed certs)
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/args/-",
        "value": "--kubelet-insecure-tls"
      }
    ]'

    log_info "Waiting for metrics-server rollout to complete..."
    kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

    log_ok "metrics-server installed!"
    echo ""
}

# =============================================================================
# PHASE 2: Deploy Core Application
# =============================================================================
deploy_application() {
    log_info "=== PHASE 2: Deploying core application ==="
    
    # Apply namespace first
    kubectl apply -f "${SCRIPT_DIR}/app/namespace.yaml"
    
    # Apply config and secrets
    kubectl apply -f "${SCRIPT_DIR}/app/configmap.yaml"
    kubectl apply -f "${SCRIPT_DIR}/app/secret.yaml"
    
    # Deploy the application
    kubectl apply -f "${SCRIPT_DIR}/app/deployment.yaml"
    kubectl apply -f "${SCRIPT_DIR}/app/service.yaml"
    kubectl apply -f "${SCRIPT_DIR}/app/ingress.yaml"
    kubectl apply -f "${SCRIPT_DIR}/app/hpa.yaml"
    kubectl apply -f "${SCRIPT_DIR}/app/pdb.yaml"

    # Wait for deployment to be ready
    log_info "Waiting for deployment to be ready..."
    kubectl rollout status deployment/complex-app -n complex-app --timeout=180s

    log_ok "Application deployed!"
    kubectl get all -n complex-app
    echo ""
}

# =============================================================================
# PHASE 3: Deploy Monitoring Stack
# =============================================================================
deploy_monitoring() {
    log_info "=== PHASE 3: Deploying monitoring stack ==="
    
    # Create monitoring namespace
    kubectl apply -f "${SCRIPT_DIR}/monitoring/namespace.yaml"

    # --- Add Helm repos ---
    log_info "Adding Helm repositories..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo update

    # --- Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager) ---
    log_info "Installing kube-prometheus-stack..."
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --values "${SCRIPT_DIR}/monitoring/prometheus/values.yaml" \
        --wait \
        --timeout 10m

    # --- Install Loki + Promtail ---
    log_info "Installing Loki stack..."
    helm upgrade --install loki grafana/loki-stack \
        --namespace monitoring \
        --values "${SCRIPT_DIR}/monitoring/loki/values.yaml" \
        --wait \
        --timeout 5m

    # --- Apply alert rules ---
    log_info "Applying Prometheus alert rules..."
    kubectl apply -f "${SCRIPT_DIR}/monitoring/prometheus/alert-rules.yaml"

    # --- Apply ServiceMonitor ---
    kubectl apply -f "${SCRIPT_DIR}/monitoring/service-monitor.yaml"

    log_ok "Monitoring stack deployed!"
    echo ""
    log_info "Access Grafana: http://localhost:30000 (admin/admin-password)"
    echo ""
}

# =============================================================================
# PHASE 4: Deploy KEDA
# =============================================================================
deploy_keda() {
    log_info "=== PHASE 4: Deploying KEDA for event-driven autoscaling ==="
    
    # Add KEDA Helm repo
    helm repo add kedacore https://kedacore.github.io/charts
    helm repo update

    # Install KEDA
    log_info "Installing KEDA..."
    helm upgrade --install keda kedacore/keda \
        --namespace keda \
        --create-namespace \
        --wait \
        --timeout 5m

    # Wait for KEDA operator
    log_info "Waiting for KEDA operator to be ready..."
    kubectl wait --namespace keda \
        --for=condition=ready pod \
        --selector=app=keda-operator \
        --timeout=120s

    # Apply ScaledObjects (skip if HPA is already managing the deployment)
    # Note: KEDA and HPA cannot both manage the same deployment
    # For this demo, we'll apply KEDA but it won't conflict because
    # KEDA creates its own HPA
    log_warn "NOTE: Removing HPA before applying KEDA ScaledObject (they can't coexist)"
    kubectl delete hpa complex-app-hpa -n complex-app --ignore-not-found=true
    
    kubectl apply -f "${SCRIPT_DIR}/keda/scaled-object.yaml"

    log_ok "KEDA deployed and ScaledObjects applied!"
    kubectl get scaledobject -n complex-app
    echo ""
}

# =============================================================================
# DESTROY: Tear down everything
# =============================================================================
destroy_cluster() {
    log_warn "=== DESTROYING cluster '${CLUSTER_NAME}' ==="
    read -p "Are you sure? This will delete the entire cluster. (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kind delete cluster --name "${CLUSTER_NAME}"
        log_ok "Cluster destroyed."
    else
        log_info "Aborted."
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
    echo "=============================================="
    echo "  Kubernetes Kind Cluster - Full Stack Setup"
    echo "=============================================="
    echo ""

    check_prerequisites

    case "${PHASE}" in
        --destroy|-d)
            destroy_cluster
            ;;
        --phase)
            case "${2:-}" in
                1) create_cluster && install_ingress_controller && install_metrics_server ;;
                2) deploy_application ;;
                3) deploy_monitoring ;;
                4) deploy_keda ;;
                *) log_error "Invalid phase. Use 1, 2, 3, or 4." ; exit 1 ;;
            esac
            ;;
        all|"")
            create_cluster
            install_ingress_controller
            install_metrics_server
            deploy_application
            deploy_monitoring
            deploy_keda
            
            echo ""
            echo "=============================================="
            echo "  SETUP COMPLETE!"
            echo "=============================================="
            echo ""
            echo "  Cluster:     kind-${CLUSTER_NAME}"
            echo "  App:         http://complex-app.local (add to /etc/hosts)"
            echo "  Grafana:     http://localhost:30000 (admin/admin-password)"
            echo "  Prometheus:  kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090"
            echo "  Alertmanager: kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093"
            echo ""
            echo "  Quick commands:"
            echo "    kubectl get pods -A                    # All pods"
            echo "    kubectl top pods -n complex-app        # Resource usage"
            echo "    kubectl get hpa -n complex-app         # HPA status"
            echo "    kubectl get scaledobject -n complex-app # KEDA status"
            echo ""
            ;;
        *)
            echo "Usage: $0 [--phase 1|2|3|4] [--destroy]"
            echo ""
            echo "  (no args)     Run all phases"
            echo "  --phase N     Run specific phase (1-4)"
            echo "  --destroy     Delete the cluster"
            exit 1
            ;;
    esac
}

main "$@"
