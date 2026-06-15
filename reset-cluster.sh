#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-data-platform-cluster}"
SKIP_HOSTS=0
LIGHT_MODE=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --light           Recreate with SKIP_MONITORING=1 and SKIP_KEDA=1
  --skip-hosts      Do not run setup-hosts.sh after bootstrap
  --cluster-name N  Override cluster name (default: data-platform-cluster)
  -h, --help        Show help

Examples:
  $0
  $0 --light
  $0 --cluster-name data-platform-cluster --skip-hosts
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --light)
      LIGHT_MODE=1
      shift
      ;;
    --skip-hosts)
      SKIP_HOSTS=1
      shift
      ;;
    --cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

log() {
  printf '[INFO] %s\n' "$1"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

need_cmd kind
need_cmd kubectl
need_cmd bash

if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  log "Deleting existing kind cluster: $CLUSTER_NAME"
  kind delete cluster --name "$CLUSTER_NAME"
else
  log "No existing cluster named $CLUSTER_NAME"
fi

log "Recreating cluster and platform"
if [[ "$LIGHT_MODE" == "1" ]]; then
  SKIP_MONITORING=1 SKIP_KEDA=1 CLUSTER_NAME="$CLUSTER_NAME" bash "$SCRIPT_DIR/bootstrap.sh"
else
  CLUSTER_NAME="$CLUSTER_NAME" bash "$SCRIPT_DIR/bootstrap.sh"
fi

if [[ "$SKIP_HOSTS" != "1" ]]; then
  if [[ -f "$SCRIPT_DIR/setup-hosts.sh" ]]; then
    log "Applying local hostname mappings"
    bash "$SCRIPT_DIR/setup-hosts.sh"
  fi
fi

log "Post-checks"
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null 2>&1 || true
kubectl get nodes
kubectl get pods -n data-platform
kubectl get pods -n analytics
kubectl get pods -n messaging
kubectl get pods -n store
kubectl get pods -n frontend

if [[ "$LIGHT_MODE" != "1" ]]; then
  kubectl get pods -n monitoring || true
fi

check_url() {
  local url="$1"
  local code
  code=$(curl -sS --max-time 8 -o /dev/null -w "%{http_code}" "$url" || echo "000")
  printf '  %-35s %s\n' "$url" "$code"
}

log "Endpoint status (HTTP code)"
check_url "http://frontend.local"
check_url "http://query.local"
check_url "http://localhost:8080/ui/"
check_url "http://localhost:15672"
if [[ "$LIGHT_MODE" != "1" ]]; then
  check_url "http://localhost:3000"
  check_url "http://prometheus.local"
  check_url "http://alertmanager.local"
fi

log "Reset complete"
