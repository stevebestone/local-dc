#!/usr/bin/env bash
#
# Datacenter-in-a-Box — Bootstrap (Containerized)
# Starts the local datacenter using Podman Compose.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# For the native k3s install (without containers), use:
#   sudo ansible-playbook -i ansible/inventory.yml ansible/playbook.yml --become
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Prerequisites ──────────────────────────────────────
echo "Checking prerequisites..."

# Podman
if ! command -v podman &>/dev/null; then
    echo "Error: Podman is not installed."
    echo "  Ubuntu/Debian: sudo apt-get install -y podman"
    echo "  Fedora:        sudo dnf install -y podman"
    exit 1
fi
echo "✓ Podman $(podman --version | awk '{print $3}')"

# Podman Compose (built-in or podman-compose)
if ! podman compose version &>/dev/null 2>&1; then
    echo "Error: 'podman compose' is not available."
    echo "  Ubuntu/Debian: sudo apt-get install -y podman-compose"
    echo "  Fedora:        sudo dnf install -y podman-compose"
    exit 1
fi
echo "✓ Podman Compose available"

# VT-x / AMD-V
if ! grep -qE '(vmx|svm)' /proc/cpuinfo; then
    echo "Error: CPU does not support VT-x/AMD-V. Enable it in BIOS."
    exit 1
fi
echo "✓ Hardware virtualization (VT-x/AMD-V)"

# /dev/kvm
if [[ ! -e /dev/kvm ]]; then
    echo "Error: /dev/kvm not available."
    echo "  Try: sudo modprobe kvm_intel  (or kvm_amd)"
    exit 1
fi
echo "✓ /dev/kvm"

# ─── Start Datacenter ───────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " Starting Local DC..."
echo "═══════════════════════════════════════════════════"

podman compose -f "$SCRIPT_DIR/compose.yaml" up -d

# Wait for bootstrap to finish
echo ""
echo "Waiting for bootstrap to complete..."
BOOTSTRAP_CONTAINER="local-dc-bootstrap-1"
TIMEOUT=600
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    STATUS=$(podman inspect --format '{{.State.Status}}' "$BOOTSTRAP_CONTAINER" 2>/dev/null || echo "waiting")
    if [[ "$STATUS" == "exited" ]]; then
        EXIT_CODE=$(podman inspect --format '{{.State.ExitCode}}' "$BOOTSTRAP_CONTAINER" 2>/dev/null || echo "1")
        if [[ "$EXIT_CODE" == "0" ]]; then
            echo "✓ Bootstrap completed successfully"
            break
        else
            echo "Error: Bootstrap failed (exit code $EXIT_CODE)"
            echo "Check logs: podman logs $BOOTSTRAP_CONTAINER"
            exit 1
        fi
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Error: Bootstrap timed out after ${TIMEOUT}s"
    echo "Check logs: podman logs $BOOTSTRAP_CONTAINER"
    exit 1
fi

# ─── Export Kubeconfig ──────────────────────────────────
KUBECONFIG_DIR="$HOME/.kube"
mkdir -p "$KUBECONFIG_DIR"

# Copy kubeconfig from k3s container
K3S_CONTAINER="local-dc-k3s-server-1"
podman cp "$K3S_CONTAINER":/output/kubeconfig.yaml "$KUBECONFIG_DIR/config-local-dc"
# Fix server URL for host access
sed -i 's|127\.0\.0\.1|localhost|g' "$KUBECONFIG_DIR/config-local-dc"
chmod 600 "$KUBECONFIG_DIR/config-local-dc"

echo "✓ Kubeconfig exported to $KUBECONFIG_DIR/config-local-dc"

# ─── Summary ────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " LOCAL DC IS RUNNING"
echo "═══════════════════════════════════════════════════"
echo ""
echo " ArgoCD is syncing components from Git."
echo " This may take 5-10 minutes for all pods to start."
echo ""
echo " To use kubectl from the host:"
echo "   export KUBECONFIG=$KUBECONFIG_DIR/config-local-dc"
echo ""
echo " Web UIs:"
echo "   ArgoCD:           http://localhost:30082"
echo "   KubeVirt Manager: http://localhost:30080"
echo "   Backstage:        http://localhost:30081"
echo "   Keycloak:         http://localhost:30083"
echo "   Grafana:          http://localhost:30084"
echo "   Harbor:           http://localhost:30085"
echo ""
echo " Lifecycle:"
echo "   Stop:    podman compose down"
echo "   Restart: podman compose up -d"
echo "   Reset:   podman compose down -v"
echo ""
echo "═══════════════════════════════════════════════════"
