#!/usr/bin/env bash
#
# Local DC — Import Backstage Image
# Builds the custom Backstage image and imports it into
# the containerized k3s cluster.
#
# Usage:
#   ./scripts/import-backstage.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
K3S_CONTAINER="${K3S_CONTAINER:-local-dc-k3s-server-1}"
IMAGE_NAME="localhost/backstage-idp:latest"

echo "═══════════════════════════════════════════════════"
echo " Building Backstage Image"
echo "═══════════════════════════════════════════════════"

# Check k3s container is running
if ! podman ps --format '{{.Names}}' | grep -q "^${K3S_CONTAINER}$"; then
  echo "Error: k3s container '${K3S_CONTAINER}' is not running."
  echo "Start the datacenter first: podman compose up -d"
  exit 1
fi

# Build the image
echo "Building ${IMAGE_NAME}..."
podman build -t "${IMAGE_NAME}" \
  -f "${PROJECT_DIR}/backstage/Dockerfile" \
  "${PROJECT_DIR}/backstage/"

# Import into k3s containerd
echo "Importing image into k3s..."
podman save "${IMAGE_NAME}" | \
  podman exec -i "${K3S_CONTAINER}" ctr -n k8s.io images import -

echo ""
echo "✓ Backstage image imported into k3s."
echo "  Restart the deployment to pick up changes:"
echo "  podman exec ${K3S_CONTAINER} kubectl -n platform rollout restart deployment/backstage"
