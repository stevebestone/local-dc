#!/usr/bin/env bash
#
# Local DC — Import Backstage Image
# Builds the custom Backstage image and imports it into
# the native k3s cluster's containerd.
#
# Usage:
#   ./scripts/import-backstage.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="localhost/backstage-idp:latest"

echo "═══════════════════════════════════════════════════"
echo " Building Backstage Image"
echo "═══════════════════════════════════════════════════"

# Check k3s is running
if ! kubectl get nodes 2>/dev/null | grep -q " Ready"; then
    echo "Error: k3s is not running."
    echo "Start the datacenter first: sudo ./setup.sh"
    exit 1
fi

# Build the image (works with Podman or Docker)
BUILDER="podman"
command -v podman &>/dev/null || BUILDER="docker"
echo "Building ${IMAGE_NAME} with ${BUILDER}..."
$BUILDER build -t "${IMAGE_NAME}" \
    -f "${PROJECT_DIR}/backstage/Dockerfile" \
    "${PROJECT_DIR}/backstage/"

# Import into k3s containerd
echo "Importing image into k3s containerd..."
$BUILDER save "${IMAGE_NAME}" | sudo ctr -n k8s.io images import -

echo ""
echo "✓ Backstage image imported into k3s."
echo "  Restart the deployment to pick up changes:"
echo "  kubectl -n platform rollout restart deployment/backstage"
