#!/usr/bin/env bash
#
# Datacenter-in-a-Box: k3s + KubeVirt on bare-metal Intel Linux
# Supports: Ubuntu/Debian, Fedora, and Bazzite/Fedora Atomic (OSTree).
#
# Usage:
#   chmod +x datacenter-setup.sh
#   sudo ./datacenter-setup.sh
#
# After the script completes, follow the printed instructions to
# download a Windows ISO and launch your first VM.

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ─── Detect distro family ────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
    fi

    # Check for immutable/OSTree distros (Bazzite, Silverblue, Kinoite, etc.)
    if command -v rpm-ostree &>/dev/null; then
        DISTRO_FAMILY="ostree"
        DISTRO_NAME="${PRETTY_NAME:-Fedora Atomic}"
    elif command -v apt-get &>/dev/null; then
        DISTRO_FAMILY="debian"
        DISTRO_NAME="${PRETTY_NAME:-Ubuntu/Debian}"
    elif command -v dnf &>/dev/null; then
        DISTRO_FAMILY="fedora"
        DISTRO_NAME="${PRETTY_NAME:-Fedora}"
    else
        fail "Unsupported distro. This script supports Ubuntu/Debian, Fedora, and Bazzite/Fedora Atomic."
    fi

    info "Detected: ${DISTRO_NAME} (${DISTRO_FAMILY})"
}

detect_distro

# ─── Pre-flight checks ──────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "This script must be run as root (sudo)."

info "Checking CPU virtualization support..."
if ! grep -qE '(vmx|svm)' /proc/cpuinfo; then
    fail "CPU does not support hardware virtualization (VT-x/AMD-V)."
fi
ok "VT-x / AMD-V detected."

info "Checking for /dev/kvm..."
if [[ ! -e /dev/kvm ]]; then
    warn "/dev/kvm not found. Loading kvm_intel module..."
    modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
    if [[ ! -e /dev/kvm ]]; then
        fail "/dev/kvm still unavailable. Enable VT-x in BIOS."
    fi
fi
ok "/dev/kvm is available."

info "Checking available memory..."
TOTAL_MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
if [[ $TOTAL_MEM_GB -lt 8 ]]; then
    fail "At least 8 GB RAM required. Detected: ${TOTAL_MEM_GB} GB."
fi
ok "${TOTAL_MEM_GB} GB RAM detected."

# ─── Install dependencies ───────────────────────────────────────────
NEEDS_REBOOT=false

install_deps_debian() {
    info "Installing system dependencies (apt)..."
    apt-get update -qq
    apt-get install -y -qq curl qemu-utils qemu-system-x86 libvirt-daemon-system \
        virtinst bridge-utils cpu-checker > /dev/null 2>&1
    ok "System dependencies installed."

    info "Verifying KVM..."
    kvm-ok || warn "kvm-ok reported issues — VMs may still work."
}

install_deps_fedora() {
    info "Installing system dependencies (dnf)..."
    dnf install -y -q curl qemu-kvm libvirt virt-install bridge-utils > /dev/null 2>&1
    systemctl enable --now libvirtd 2>/dev/null || true
    ok "System dependencies installed."
}

install_deps_ostree() {
    info "Detected immutable OS (OSTree). Checking existing packages..."

    # On Bazzite/Fedora Atomic, many virt packages are already in the base image.
    # Only layer what's missing. Prefer not layering if possible.
    MISSING_PKGS=()

    # Check for essential commands; only layer packages if truly missing
    command -v curl     &>/dev/null || MISSING_PKGS+=("curl")
    command -v qemu-img &>/dev/null || MISSING_PKGS+=("qemu-img")
    command -v virsh    &>/dev/null || MISSING_PKGS+=("libvirt" "qemu-kvm")
    command -v brctl    &>/dev/null || MISSING_PKGS+=("bridge-utils")

    if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
        info "Layering missing packages: ${MISSING_PKGS[*]}"
        info "(rpm-ostree will stage changes; a reboot may be required)"
        rpm-ostree install --idempotent --allow-inactive "${MISSING_PKGS[@]}"

        # Check if a reboot is needed (rpm-ostree stages for next boot)
        if rpm-ostree status | grep -q "Staged"; then
            NEEDS_REBOOT=true
            warn "Packages staged. A reboot is required before they take effect."
            warn "After rebooting, re-run this script to continue setup."
        fi
    else
        ok "All required packages are already available."
    fi

    # Enable libvirtd if present
    systemctl enable --now libvirtd 2>/dev/null || true
}

case "$DISTRO_FAMILY" in
    debian) install_deps_debian ;;
    fedora) install_deps_fedora ;;
    ostree) install_deps_ostree ;;
esac

if [[ "$NEEDS_REBOOT" == true ]]; then
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  REBOOT REQUIRED${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Layered packages have been staged by rpm-ostree."
    echo "  Please reboot and re-run this script:"
    echo ""
    echo "    sudo reboot"
    echo "    sudo ./datacenter-setup.sh"
    echo ""
    exit 0
fi

# ─── SELinux configuration ───────────────────────────────────────────
if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    info "SELinux is active ($(getenforce)). Configuring policies..."

    # Allow containers and k3s to use NFS, connect to any port, etc.
    setsebool -P container_use_cephfs on 2>/dev/null || true
    setsebool -P virt_sandbox_use_all_caps on 2>/dev/null || true
    setsebool -P virt_use_nfs on 2>/dev/null || true

    # k3s needs to write to various system paths; set permissive domain
    # for container_t if strict mode causes issues
    if command -v semanage &>/dev/null; then
        # Allow k3s data directory
        semanage fcontext -a -t container_var_lib_t '/var/lib/rancher/k3s(/.*)?'  2>/dev/null || true
        restorecon -R /var/lib/rancher 2>/dev/null || true
    fi

    ok "SELinux policies configured."
else
    info "SELinux is not active — skipping policy configuration."
fi

# ─── Install k3s ────────────────────────────────────────────────────
if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null; then
    ok "k3s is already installed and running."
else
    info "Installing k3s..."

    # On SELinux-enabled systems, k3s needs the selinux RPM policy
    if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        info "Installing k3s SELinux policy..."
        if [[ "$DISTRO_FAMILY" == "ostree" ]]; then
            rpm-ostree install --idempotent --allow-inactive k3s-selinux 2>/dev/null || \
                warn "k3s-selinux package not found — k3s will install it automatically."
        elif [[ "$DISTRO_FAMILY" == "fedora" ]]; then
            dnf install -y -q k3s-selinux 2>/dev/null || \
                warn "k3s-selinux package not found — k3s will install it automatically."
        fi

        # Install k3s with SELinux enforcement
        curl -sfL https://get.k3s.io | INSTALL_K3S_SELINUX_WARN=true sh -s - --selinux
    else
        curl -sfL https://get.k3s.io | sh -
    fi

    chmod 644 /etc/rancher/k3s/k3s.yaml

    info "Waiting for k3s node to become Ready..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    until kubectl get nodes | grep -q " Ready"; do sleep 3; done
    ok "k3s is running."
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Make kubeconfig accessible to the regular user
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
mkdir -p "$REAL_HOME/.kube"
cp /etc/rancher/k3s/k3s.yaml "$REAL_HOME/.kube/config"
chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME/.kube"

# ─── Install KubeVirt ───────────────────────────────────────────────
info "Fetching latest stable KubeVirt version..."
KUBEVIRT_VERSION=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
info "Installing KubeVirt ${KUBEVIRT_VERSION}..."

if kubectl get namespace kubevirt &>/dev/null; then
    warn "KubeVirt namespace already exists — skipping operator install."
else
    kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
fi

if kubectl get kubevirt kubevirt -n kubevirt &>/dev/null; then
    warn "KubeVirt CR already exists — skipping."
else
    kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
fi

info "Waiting for KubeVirt to become available (this may take a few minutes)..."
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=600s
ok "KubeVirt ${KUBEVIRT_VERSION} is ready."

# ─── Install CDI (Containerized Data Importer) ──────────────────────
info "Fetching latest stable CDI version..."
CDI_VERSION=$(curl -s https://api.github.com/repos/kubevirt/containerized-data-importer/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)
info "Installing CDI ${CDI_VERSION}..."

if kubectl get namespace cdi &>/dev/null; then
    warn "CDI namespace already exists — skipping."
else
    kubectl create -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
    kubectl create -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"
fi

info "Waiting for CDI to become available..."
kubectl wait cdi cdi --for condition=Available --timeout=300s
ok "CDI ${CDI_VERSION} is ready."

# ─── Install virtctl ────────────────────────────────────────────────
info "Installing virtctl..."
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  VIRTCTL_ARCH="amd64" ;;
    aarch64) VIRTCTL_ARCH="arm64" ;;
    *)       fail "Unsupported architecture: $ARCH" ;;
esac

curl -L -o /usr/local/bin/virtctl \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-${VIRTCTL_ARCH}"
chmod +x /usr/local/bin/virtctl
ok "virtctl installed: $(virtctl version --client 2>&1 | head -1)"

# ─── Create Windows VM manifest ─────────────────────────────────────
info "Creating Windows VM manifest..."
cat > "$REAL_HOME/windows-vm.yaml" <<'MANIFEST'
# Windows VM for KubeVirt on x86_64 bare-metal
# Prerequisites:
#   1. Download a Windows ISO and import it (see instructions below)
#   2. Create the OS disk PVC
#
# Quick start after importing the ISO:
#   kubectl apply -f windows-vm.yaml
#   virtctl start windows-vm
#   virtctl vnc windows-vm        # graphical console
#   virtctl console windows-vm    # serial console
---
# PVC for Windows OS disk (60 GB)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: windows-os-disk
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 60Gi
---
# DataVolume to import the Windows ISO into a PVC
# Update the URL below or use: virtctl image-upload ...
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: windows-iso
spec:
  source:
    http:
      # Replace with the direct URL to your Windows ISO, or use
      # virtctl image-upload to upload a local ISO file:
      #   virtctl image-upload dv windows-iso \
      #     --size=6Gi \
      #     --image-path=/path/to/Win11.iso \
      #     --uploadproxy-url=https://$(kubectl get svc -n cdi cdi-uploadproxy -o jsonpath='{.spec.clusterIP}'):443 \
      #     --insecure
      url: "https://REPLACE_WITH_YOUR_WINDOWS_ISO_URL"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 6Gi
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: windows-vm
  labels:
    app: windows-vm
spec:
  runStrategy: Manual
  template:
    metadata:
      labels:
        kubevirt.io/vm: windows-vm
        os.template.kubevirt.io/win11: "true"
    spec:
      domain:
        cpu:
          cores: 4
          threads: 2
          model: host-passthrough
        resources:
          requests:
            memory: 8Gi
        features:
          acpi: {}
          hyperv:
            relaxed: {}
            vapic: {}
            spinlocks:
              spinlocks: 8191
            synic: {}
            stimer:
              direct: {}
            reset: {}
            vpindex: {}
            frequencies: {}
            reenlightenment: {}
            tlbflush: {}
            ipi: {}
        clock:
          utc: {}
          timer:
            hpet:
              present: false
            pit:
              tickPolicy: delay
            rtc:
              tickPolicy: catchup
            hyperv: {}
        firmware:
          bootloader:
            efi:
              secureBoot: true
        machine:
          type: q35
        devices:
          disks:
            - name: osdisk
              disk:
                bus: virtio
              bootOrder: 2
            - name: cdrom-iso
              cdrom:
                bus: sata
              bootOrder: 1
            - name: virtio-drivers
              cdrom:
                bus: sata
          inputs:
            - name: tablet
              type: tablet
              bus: usb
          interfaces:
            - name: default
              masquerade: {}
              model: virtio
          tpm: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: osdisk
          persistentVolumeClaim:
            claimName: windows-os-disk
        - name: cdrom-iso
          dataVolume:
            name: windows-iso
        - name: virtio-drivers
          containerDisk:
            image: quay.io/kubevirt/virtio-container-disk:latest
MANIFEST

chown "$REAL_USER":"$REAL_USER" "$REAL_HOME/windows-vm.yaml"
ok "Windows VM manifest created at $REAL_HOME/windows-vm.yaml"

# ─── Create Linux demo VM manifest ──────────────────────────────────
info "Creating Linux demo VM manifest..."
cat > "$REAL_HOME/linux-demo-vm.yaml" <<'MANIFEST'
# Lightweight Linux VM for quick KubeVirt verification
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: linux-demo
  labels:
    app: linux-demo
spec:
  runStrategy: Manual
  template:
    metadata:
      labels:
        kubevirt.io/vm: linux-demo
    spec:
      domain:
        cpu:
          cores: 1
          model: host-passthrough
        resources:
          requests:
            memory: 128Mi
        devices:
          disks:
            - name: containerdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: containerdisk
          containerDisk:
            image: quay.io/kubevirt/cirros-container-disk-demo:latest
MANIFEST

chown "$REAL_USER":"$REAL_USER" "$REAL_HOME/linux-demo-vm.yaml"
ok "Linux demo VM manifest created at $REAL_HOME/linux-demo-vm.yaml"

# ─── Deploy and verify with Linux demo VM ───────────────────────────
info "Deploying Linux demo VM to verify KubeVirt..."
kubectl apply -f "$REAL_HOME/linux-demo-vm.yaml"
virtctl start linux-demo

info "Waiting for demo VM to reach Running state..."
for i in $(seq 1 60); do
    PHASE=$(kubectl get vmi linux-demo -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [[ "$PHASE" == "Running" ]]; then
        break
    fi
    sleep 5
done

if [[ "$PHASE" == "Running" ]]; then
    ok "Linux demo VM is running!"
    VMI_IP=$(kubectl get vmi linux-demo -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "N/A")
    ok "Demo VM IP: $VMI_IP"
else
    warn "Demo VM phase: $PHASE (may still be pulling the container image)"
fi

# ─── Summary ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  DATACENTER SETUP COMPLETE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}k3s:${NC}      $(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
echo -e "  ${CYAN}KubeVirt:${NC} ${KUBEVIRT_VERSION}"
echo -e "  ${CYAN}CDI:${NC}      ${CDI_VERSION}"
echo -e "  ${CYAN}virtctl:${NC}  installed"
echo -e "  ${CYAN}Distro:${NC}   ${DISTRO_NAME}"
echo -e "  ${CYAN}RAM:${NC}      ${TOTAL_MEM_GB} GB"
echo ""
echo -e "  ${CYAN}Manifests:${NC}"
echo -e "    $REAL_HOME/linux-demo-vm.yaml   (deployed & running)"
echo -e "    $REAL_HOME/windows-vm.yaml      (ready — needs ISO)"
echo ""
echo -e "${YELLOW}── Next steps for Windows VM ──${NC}"
echo ""
echo "  1. Download a Windows 11 evaluation ISO:"
echo "     https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise"
echo ""
echo "  2. Upload the ISO into the cluster:"
echo "     virtctl image-upload dv windows-iso \\"
echo "       --size=6Gi \\"
echo "       --image-path=/path/to/Win11_Enterprise.iso \\"
echo "       --uploadproxy-url=https://\$(kubectl get svc -n cdi cdi-uploadproxy -o jsonpath='{.spec.clusterIP}'):443 \\"
echo "       --insecure"
echo ""
echo "  3. Deploy the Windows VM:"
echo "     kubectl apply -f ~/windows-vm.yaml"
echo "     virtctl start windows-vm"
echo ""
echo "  4. Open the graphical console to install Windows:"
echo "     virtctl vnc windows-vm"
echo ""
echo -e "${YELLOW}── Useful commands ──${NC}"
echo ""
echo "  kubectl get vm,vmi                # list VMs"
echo "  virtctl start <vm>                # start a VM"
echo "  virtctl stop <vm>                 # stop a VM"
echo "  virtctl console <vm>              # serial console"
echo "  virtctl vnc <vm>                  # graphical console"
echo "  virtctl ssh <user>@<vm>           # SSH into a VM"
echo "  kubectl get pods -n kubevirt      # KubeVirt status"
echo ""
