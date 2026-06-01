#!/usr/bin/env bash
#
# Datacenter-in-a-Box — Bootstrap (Native k3s + OpenTofu)
#
# Installs k3s natively, then uses OpenTofu to deploy ArgoCD
# and the root App-of-Apps. ArgoCD syncs all remaining
# components from Git.
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
DEPLOY_USER="${SUDO_USER:-$(whoami)}"
DEPLOY_HOME="$(eval echo ~"$DEPLOY_USER")"

# ─── Must run as root ────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./setup.sh"; exit 1; }

# ─── Prerequisites ───────────────────────────────────────
echo "Checking prerequisites..."

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

# curl
if ! command -v curl &>/dev/null; then
    echo "Installing curl..."
    apt-get update -qq && apt-get install -y -qq curl
fi

# ─── Install k3s ─────────────────────────────────────────
export KUBECONFIG="$K3S_KUBECONFIG"

if command -v k3s &>/dev/null && kubectl get nodes 2>/dev/null | grep -q " Ready"; then
    echo "✓ k3s already installed and running"
else
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo " Installing k3s..."
    echo "═══════════════════════════════════════════════════"
    curl -sfL https://get.k3s.io | sh -

    echo "Waiting for k3s to be ready..."
    TIMEOUT=120
    ELAPSED=0
    until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        if [[ $ELAPSED -ge $TIMEOUT ]]; then
            echo "Error: k3s did not become ready within ${TIMEOUT}s"
            exit 1
        fi
    done
    echo "✓ k3s is ready"
fi

# Make kubeconfig readable
chmod 644 "$K3S_KUBECONFIG"

# ─── Setup kubeconfig for user ───────────────────────────
mkdir -p "$DEPLOY_HOME/.kube"
cp "$K3S_KUBECONFIG" "$DEPLOY_HOME/.kube/config"
chown "$DEPLOY_USER":"$DEPLOY_USER" "$DEPLOY_HOME/.kube/config"
chmod 600 "$DEPLOY_HOME/.kube/config"

# Add KUBECONFIG to bashrc if not present
if ! grep -q "KUBECONFIG=" "$DEPLOY_HOME/.bashrc" 2>/dev/null; then
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> "$DEPLOY_HOME/.bashrc"
fi

# ─── Install OpenTofu ────────────────────────────────────
if ! command -v tofu &>/dev/null; then
    echo "Installing OpenTofu..."
    curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
    chmod +x /tmp/install-opentofu.sh
    /tmp/install-opentofu.sh --install-method deb
    rm -f /tmp/install-opentofu.sh
fi
echo "✓ OpenTofu $(tofu --version | head -1)"

# ─── Install Helm ────────────────────────────────────────
if ! command -v helm &>/dev/null; then
    echo "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
echo "✓ Helm $(helm version --short)"

# ─── Install virtctl ─────────────────────────────────────
if ! command -v virtctl &>/dev/null; then
    echo "Installing virtctl..."
    KV_VERSION=$(curl -sL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
    ARCH="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && ARCH="arm64"
    curl -Lo /usr/local/bin/virtctl \
        "https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}/virtctl-${KV_VERSION}-linux-${ARCH}"
    chmod +x /usr/local/bin/virtctl
fi
echo "✓ virtctl"

# ─── OpenTofu: Bootstrap ArgoCD + App-of-Apps ────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " Bootstrapping with OpenTofu..."
echo "═══════════════════════════════════════════════════"

# Detect host IP for OIDC URLs
HOST_IP=$(hostname -I | awk '{print $1}')

# Run as the deploy user so state files are owned correctly
# Stage 1: install ArgoCD (registers the Application CRD)
# Stage 2: apply the root App-of-Apps (requires the CRD to exist at plan time)
su - "$DEPLOY_USER" -c "
    export KUBECONFIG=$K3S_KUBECONFIG
    cd '$SCRIPT_DIR/tofu'
    tofu init -input=false
    tofu apply -auto-approve -input=false \\
        -target=kubernetes_namespace.argocd \\
        -target=helm_release.argocd \\
        -var='host_ip=$HOST_IP' \\
        -var='repo_url=${REPO_URL:-https://github.com/stevebestone/local-dc.git}' \\
        -var='target_revision=${TARGET_REVISION:-main}'
    tofu apply -auto-approve -input=false \\
        -var='host_ip=$HOST_IP' \\
        -var='repo_url=${REPO_URL:-https://github.com/stevebestone/local-dc.git}' \\
        -var='target_revision=${TARGET_REVISION:-main}'
"

# ─── Summary ─────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " LOCAL DC IS RUNNING"
echo "═══════════════════════════════════════════════════"
echo ""
echo " ArgoCD is syncing components from Git."
echo " This may take 5-10 minutes for all pods to start."
echo ""
echo " Deployment order (sync-waves):"
echo "   1. Keycloak         (identity provider)"
echo "   2. Monitoring       (Prometheus + Grafana)"
echo "   3. Harbor           (container registry)"
echo "   4. KubeVirt + CDI   (virtualization)"
echo "   5. KubeVirt Manager (VM dashboard)"
echo "   6. Backstage        (developer portal)"
echo ""
echo " To use kubectl:"
echo "   export KUBECONFIG=$K3S_KUBECONFIG"
echo ""
echo " Web UIs:"
echo "   ArgoCD:           http://localhost:30082"
echo "   KubeVirt Manager: http://${HOST_IP}:30080"
echo "   Backstage:        http://${HOST_IP}:30081"
echo "   Keycloak:         http://${HOST_IP}:30083"
echo "   Grafana:          http://${HOST_IP}:30084"
echo "   Harbor:           http://${HOST_IP}:30085"
echo ""
echo " ArgoCD admin password:"
echo "   kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "     -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo " Lifecycle:"
echo "   Teardown: tofu -chdir=tofu destroy"
echo "   Uninstall k3s: /usr/local/bin/k3s-uninstall.sh"
echo ""
echo "═══════════════════════════════════════════════════"
