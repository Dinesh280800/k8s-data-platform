#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect engine if not explicitly set
if [[ -z "${ENGINE:-}" ]]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ENGINE=docker
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    ENGINE=podman
    export KIND_EXPERIMENTAL_PROVIDER=podman
  else
    echo "No running container engine found (tried docker, podman)."
    exit 1
  fi
fi

CLUSTER_NAME="${CLUSTER_NAME:-data-platform-cluster}"
IMAGES=(
  "data-platform/api-discovery:local|services/api-discovery/Dockerfile"
  "data-platform/api-validator:local|services/api-validator/Dockerfile"
  "data-platform/api-enricher:local|services/api-enricher/Dockerfile"
  "data-platform/query-router:local|services/query-router/Dockerfile"
)

echo "[build] Using engine: $ENGINE"

for entry in "${IMAGES[@]}"; do
  image="${entry%%|*}"
  dockerfile="${entry##*|}"
  echo "[build] $image"
  "$ENGINE" build -t "$image" -f "$SCRIPT_DIR/$dockerfile" "$SCRIPT_DIR"
done

if command -v kind >/dev/null 2>&1 && kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "[load] Loading images into kind cluster: $CLUSTER_NAME"
  for entry in "${IMAGES[@]}"; do
    image="${entry%%|*}"
    if [[ "$ENGINE" == "podman" ]]; then
      # Podman: save to tarball, then kind load from archive
      tmp="$(mktemp /tmp/kind-image-XXXXXX.tar)"
      podman save "$image" -o "$tmp"
      kind load image-archive "$tmp" --name "$CLUSTER_NAME"
      rm -f "$tmp"
    else
      kind load docker-image "$image" --name "$CLUSTER_NAME"
    fi
  done
fi

echo "[build] Done"
