#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apply_all() {
  kubectl apply -f "${SCRIPT_DIR}/services/namespace.yaml"
  kubectl apply -f "${SCRIPT_DIR}/services/api-discovery/k8s.yaml"
  kubectl apply -f "${SCRIPT_DIR}/services/api-validator/k8s.yaml"
  kubectl apply -f "${SCRIPT_DIR}/services/api-enricher/k8s.yaml"
  kubectl apply -f "${SCRIPT_DIR}/services/query-router/k8s.yaml"
  kubectl apply -f "${SCRIPT_DIR}/services/frontend/k8s.yaml"

  kubectl apply -f "${SCRIPT_DIR}/platform/broker/k8s.yaml"
  kubectl apply -f "${SCRIPT_DIR}/platform/store/k8s.yaml"
  kubectl apply -f "${SCRIPT_DIR}/platform/query/trino.yaml"

  kubectl apply -f "${SCRIPT_DIR}/keda/scaled-object.yaml"

  if kubectl get namespace monitoring >/dev/null 2>&1; then
    kubectl apply -f "${SCRIPT_DIR}/monitoring/platform-service-monitor.yaml"
    kubectl apply -f "${SCRIPT_DIR}/monitoring/platform-prometheus-rules.yaml"
  else
    echo "Monitoring namespace not found; skipping ServiceMonitor and PrometheusRule."
    echo "Install the monitoring stack first if you want metrics and alerts."
  fi
}

wait_ready() {
  kubectl rollout status deployment/api-discovery -n data-platform --timeout=180s || true
  kubectl rollout status deployment/api-validator -n data-platform --timeout=180s || true
  kubectl rollout status deployment/api-enricher -n data-platform --timeout=180s || true
  kubectl rollout status deployment/query-router -n data-platform --timeout=180s || true
  kubectl rollout status deployment/frontend -n frontend --timeout=180s || true
  kubectl rollout status deployment/rabbitmq -n messaging --timeout=180s || true
  kubectl rollout status deployment/postgres -n store --timeout=180s || true
  kubectl rollout status deployment/trino-coordinator -n analytics --timeout=180s || true
}

case "${1:-apply}" in
  apply)
    apply_all
    wait_ready
    ;;
  delete)
    kubectl delete namespace data-platform messaging analytics frontend store --ignore-not-found=true
    ;;
  *)
    echo "Usage: $0 [apply|delete]"
    exit 1
    ;;
esac
