#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="data-platform-cluster"

log() {
  echo "[INFO] $1"
}

detect_runtime() {
  # Prefer the engine already set in the environment
  if [[ -n "${ENGINE:-}" ]]; then
    export ENGINE
    if [[ "$ENGINE" == "podman" ]]; then
      export KIND_EXPERIMENTAL_PROVIDER=podman
    fi
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    export ENGINE=docker
    return 0
  fi
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    export ENGINE=podman
    export KIND_EXPERIMENTAL_PROVIDER=podman
    log "Using Podman as container runtime"
    return 0
  fi
  echo "ERROR: Neither Docker nor Podman is running."
  exit 1
}

check_prereqs() {
  for cmd in kind kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Required command not found: $cmd"
      exit 1
    fi
  done
  detect_runtime
}

create_cluster() {
  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    log "Using existing kind cluster ${CLUSTER_NAME}"
    return 0
  fi
  log "Creating kind cluster ${CLUSTER_NAME}"
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/cluster/kind-config.yaml" --wait 120s
  kubectl config use-context "kind-${CLUSTER_NAME}"
}

build_platform_images() {
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
    log "Skipping image build (SKIP_BUILD=1)"
    return 0
  fi
  log "Building platform service images and loading into kind (engine=${ENGINE})"
  ENGINE="${ENGINE}" CLUSTER_NAME="${CLUSTER_NAME}" bash "${SCRIPT_DIR}/build-images.sh"
}

install_ingress() {
  log "Installing ingress-nginx"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
  # Ensure controller lands on control-plane where kind maps host ports 80/443.
  kubectl -n ingress-nginx patch deployment ingress-nginx-controller \
    --type='merge' \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/hostname":"data-platform-cluster-control-plane"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}' || true
  kubectl wait -n ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s
}

install_metrics_server() {
  log "Installing metrics-server"
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl patch deployment metrics-server -n kube-system \
    --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' || true
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
}

install_monitoring() {
  log "Installing monitoring stack (Prometheus + Grafana + Loki)"
  kubectl apply -f "${SCRIPT_DIR}/monitoring/namespace.yaml"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --values "${SCRIPT_DIR}/monitoring/prometheus/values.yaml" \
    --wait \
    --timeout 10m
  helm upgrade --install loki grafana/loki-stack \
    --namespace monitoring \
    --values "${SCRIPT_DIR}/monitoring/loki/values.yaml" \
    --wait \
    --timeout 5m
}

install_keda() {
  log "Installing KEDA"
  helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install keda kedacore/keda \
    --namespace keda --create-namespace --wait --timeout 5m
}

print_access() {
  local hosts_hint=""
  if ! grep -q "frontend.local" /etc/hosts 2>/dev/null; then
    hosts_hint=" (add '127.0.0.1 frontend.local query.local' to /etc/hosts first)"
  fi
  cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║  Data Platform is up!                                        ║
╠══════════════════════════════════════════════════════════════╣
║  Frontend      http://frontend.local${hosts_hint:0:28}
║  Query Router  http://query.local                            ║
║  Grafana       http://localhost:3000  (admin / admin-password)
║  RabbitMQ UI   http://localhost:15672 (guest / guest)        ║
║  Trino UI      http://localhost:8080                         ║
╠══════════════════════════════════════════════════════════════╣
║  Add to /etc/hosts:  127.0.0.1  frontend.local query.local   ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

main() {
  check_prereqs
  create_cluster
  build_platform_images
  install_ingress
  install_metrics_server
  if [[ "${SKIP_MONITORING:-0}" != "1" ]]; then
    install_monitoring
  fi
  if [[ "${SKIP_KEDA:-0}" != "1" ]]; then
    install_keda
  fi
  "${SCRIPT_DIR}/bootstrap-data-platform.sh" apply
  print_access
}

main "$@"
