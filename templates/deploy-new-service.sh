#!/usr/bin/env bash
# =============================================================================
# DEPLOY NEW SERVICE
# =============================================================================
# Quickly deploy a new service using the template.
#
# Usage:
#   ./templates/deploy-new-service.sh <service-name> <image> <port>
#
# Example:
#   ./templates/deploy-new-service.sh user-api python:3.12-slim 5000
#   ./templates/deploy-new-service.sh order-service node:20-alpine 3000
# =============================================================================

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <service-name> <container-image> <port>"
    echo ""
    echo "Examples:"
    echo "  $0 user-api python:3.12-slim 5000"
    echo "  $0 order-service node:20-alpine 3000"
    echo "  $0 payment-svc nginx:alpine 8080"
    exit 1
fi

SERVICE_NAME="$1"
SERVICE_IMAGE="$2"
SERVICE_PORT="$3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Deploying service: ${SERVICE_NAME}"
echo "  Image: ${SERVICE_IMAGE}"
echo "  Port:  ${SERVICE_PORT}"
echo ""

# Apply template with substitutions
sed "s|SERVICE_NAME|${SERVICE_NAME}|g; s|SERVICE_IMAGE|${SERVICE_IMAGE}|g; s|SERVICE_PORT|${SERVICE_PORT}|g" \
    "${SCRIPT_DIR}/new-service-template.yaml" | kubectl apply -f -

echo ""
echo "Waiting for deployment..."
kubectl rollout status deployment/"${SERVICE_NAME}" -n "${SERVICE_NAME}" --timeout=120s

echo ""
echo "✓ Service '${SERVICE_NAME}' deployed successfully!"
echo ""
echo "  Pods:    kubectl get pods -n ${SERVICE_NAME}"
echo "  Logs:    kubectl logs -n ${SERVICE_NAME} -l app.kubernetes.io/name=${SERVICE_NAME}"
echo "  Access:  kubectl port-forward -n ${SERVICE_NAME} svc/${SERVICE_NAME} ${SERVICE_PORT}:80"
echo "  Delete:  kubectl delete namespace ${SERVICE_NAME}"
echo ""
echo "  For Ingress access, add to /etc/hosts:"
echo "    echo '127.0.0.1 ${SERVICE_NAME}.local' | sudo tee -a /etc/hosts"
