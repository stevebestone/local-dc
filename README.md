# Local DC — Datacenter-in-a-Box

A fully GitOps-managed local datacenter running inside Podman containers, powered by k3s, KubeVirt, ArgoCD, Backstage, and Keycloak.

Engineers self-provision development VMs through the Backstage Developer Portal. All infrastructure is declared in Git and synced by ArgoCD.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Host — Intel i9 / 64 GB RAM — Ubuntu Linux              │
│                                                          │
│  ┌── Podman Container: k3s-server ────────────────────┐  │
│  │   k3s (Kubernetes) — privileged + /dev/kvm          │  │
│  │                                                     │  │
│  │   argocd        → ArgoCD (GitOps controller)        │  │
│  │   platform      → Backstage IDP + KubeVirt Manager  │  │
│  │   keycloak      → Keycloak IAM (OIDC provider)      │  │
│  │   kubevirt      → KubeVirt operator                  │  │
│  │   cdi           → Containerized Data Importer        │  │
│  │   monitoring    → Prometheus + Grafana               │  │
│  │   harbor        → Container registry                 │  │
│  │   developers    → Engineer VMs (KubeVirt)            │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                          │
│  podman compose up   → Bootstrap k3s + ArgoCD + GitOps   │
│  podman compose down → Clean shutdown                    │
│  Git repo → ArgoCD → All cluster resources               │
│  Engineer → Backstage → VM provisioning                  │
└──────────────────────────────────────────────────────────┘
```

## Components

| Component | Version | Namespace | Description |
|-----------|---------|-----------|-------------|
| k3s | v1.35.5 | — | Lightweight Kubernetes (in Podman container) |
| ArgoCD | stable | `argocd` | GitOps continuous delivery |
| KubeVirt | v1.8.2 | `kubevirt` | VM management on Kubernetes |
| CDI | v1.65.0 | `cdi` | VM disk image management |
| KubeVirt Manager | latest | `platform` | Web UI for VM operations |
| Backstage | 1.51 (custom) | `platform` | Internal Developer Portal |
| Keycloak | 26.0 | `keycloak` | Identity & Access Management |
| Prometheus | latest | `monitoring` | Metrics collection (14-day retention) |
| Grafana | latest | `monitoring` | Monitoring dashboards |
| Harbor | latest | `harbor` | Container/artifact registry |

## Web UIs

| Service | URL | Auth |
|---------|-----|------|
| **Backstage** (Developer Portal) | `http://localhost:30081` | Keycloak OIDC / Guest |
| **ArgoCD** (GitOps Dashboard) | `http://localhost:30082` | Keycloak OIDC |
| **Keycloak** (IAM Admin) | `http://localhost:30083` | admin / admin |
| **Grafana** (Monitoring) | `http://localhost:30084` | admin / (see secret) |
| **Harbor** (Container Registry) | `http://localhost:30085` | Keycloak OIDC |
| **KubeVirt Manager** (VM Dashboard) | `http://localhost:30080` | No auth |

## Quick Start

### Prerequisites

- Linux (Ubuntu, Fedora, or Bazzite) with Intel/AMD CPU
- VT-x/AMD-V enabled in BIOS
- `/dev/kvm` available
- Podman + Podman Compose installed
- At least 16 GB RAM (64 GB recommended)

### Install

```bash
git clone https://github.com/stevebestone/local-dc.git
cd local-dc
chmod +x setup.sh
./setup.sh
```

The setup script:
1. Checks prerequisites (Podman, VT-x, /dev/kvm)
2. Runs `podman compose up -d` (starts k3s in a container)
3. Waits for the bootstrap container to install ArgoCD and create the root App-of-Apps
4. Exports kubeconfig for host `kubectl` access

After setup, ArgoCD automatically deploys: KubeVirt, CDI, KubeVirt Manager, Keycloak, Backstage, Harbor, Monitoring.

### Lifecycle

```bash
# Start the datacenter
podman compose up -d

# Stop (preserves all data in named volumes)
podman compose down

# Stop and destroy all state (fresh start)
podman compose down -v

# View logs
podman logs local-dc-k3s-server-1
podman logs local-dc-bootstrap-1
```

### Using kubectl from the host

After running `setup.sh`, a kubeconfig is exported:

```bash
export KUBECONFIG=~/.kube/config-local-dc
kubectl get nodes
kubectl get pods -A
```

Or use `podman exec` for one-off commands:

```bash
podman exec local-dc-k3s-server-1 kubectl get pods -A
```

### Build Custom Backstage Image

The custom Backstage image includes GitHub OAuth, OIDC (Keycloak), Kubernetes, TechDocs, and other plugins.

```bash
# Build and import into the containerized k3s
./scripts/import-backstage.sh

# Or manually:
podman build -t localhost/backstage-idp:latest -f backstage/Dockerfile backstage/
podman save localhost/backstage-idp:latest | \
  podman exec -i local-dc-k3s-server-1 ctr -n k8s.io images import -
```

## Login Procedures

### Backstage (Developer Portal)

1. Open `http://localhost:30081`
2. Choose login method:
   - **Guest**: Click "Enter" (no credentials, development mode)
   - **OIDC (Keycloak)**: Click "OIDC" → redirects to Keycloak login
3. Enter Keycloak credentials (see user table below)
4. First login requires password change

### ArgoCD

1. Open `http://localhost:30082`
2. Login options:
   - **Keycloak**: Click "Log in via Keycloak" → use Keycloak credentials
   - **Local admin**: Username `admin`, password:
     ```bash
     podman exec local-dc-k3s-server-1 kubectl -n argocd \
       get secret argocd-initial-admin-secret \
       -o jsonpath='{.data.password}' | base64 -d && echo
     ```

### Keycloak Admin Console

1. Open `http://localhost:30083`
2. Login: `admin` / `admin`
3. Select realm: `local-dc`

### Harbor

1. Open `http://localhost:30085`
2. Click **"LOGIN VIA OIDC PROVIDER"**
3. Keycloak login page → enter credentials
4. Users in `admins` group get Harbor admin access

### Grafana

1. Open `http://localhost:30084`
2. Username: `admin`, password:
   ```bash
   podman exec local-dc-k3s-server-1 kubectl -n monitoring \
     get secret monitoring-grafana \
     -o jsonpath='{.data.admin-password}' | base64 -d && echo
   ```

### Users (Keycloak realm: local-dc)

| Username | Group | Role | Access |
|----------|-------|------|--------|
| platform-admin | platform-admins, admins | admin, platform-admin | All applications (SSO) |
| steve | admins | admin | All applications |
| engineer1-5 | engineers | developer | Backstage + ArgoCD (read-only) |

The `platform-admin` account is the unified service account for OIDC integration across all applications (Backstage, ArgoCD, Grafana, Harbor).

Passwords are set via `secrets/create-secrets.sh` (never in Git).

### Credential Management

All secrets are stored as Kubernetes Secrets, never in Git:

```bash
# Bootstrap all secrets (local only, gitignored)
podman exec local-dc-k3s-server-1 /bin/sh -c 'cat | sh' < secrets/create-secrets.sh

# Or exec into the container
podman exec -it local-dc-k3s-server-1 sh
```

A pre-commit hook (`.githooks/pre-commit`) blocks commits containing hardcoded credentials.

## VM Provisioning

### Via Backstage (Self-Service)

1. Log into Backstage at `:30081`
2. Click **"Create..."** in the sidebar
3. Choose a template: **Ubuntu Development VM** or **Linux Mint Development VM**
4. Fill in: VM name, owner, CPU, RAM, disk size
5. Submit

### Via GitOps (Manual)

Add a VM manifest to `gitops/vms/`, update `kustomization.yaml`, commit, and push:

```yaml
# gitops/vms/my-vm.yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: my-vm
  labels:
    owner: engineer-1
    managed-by: backstage
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        cpu:
          cores: 2
          model: host-passthrough
        resources:
          requests:
            memory: 2Gi
        devices:
          disks:
            - name: disk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: disk
          containerDisk:
            image: quay.io/kubevirt/cirros-container-disk-demo:latest
```

ArgoCD syncs automatically — the VM appears within ~3 minutes.

### VM Management Commands

```bash
# Set kubeconfig (or prefix commands with podman exec)
export KUBECONFIG=~/.kube/config-local-dc

# List all VMs
kubectl get vm,vmi -n developers

# Start / Stop / Restart (install virtctl on host, or exec into container)
podman exec local-dc-k3s-server-1 virtctl start <vm-name> -n developers
podman exec local-dc-k3s-server-1 virtctl stop <vm-name> -n developers
podman exec local-dc-k3s-server-1 virtctl restart <vm-name> -n developers

# Console access
podman exec -it local-dc-k3s-server-1 virtctl console <vm-name> -n developers
```

## Configuration

Configuration is managed via the `.env` file in the project root:

```bash
# k3s version
K3S_VERSION=v1.35.5-k3s1

# Git repo and branch for ArgoCD
REPO_URL=https://github.com/stevebestone/local-dc.git
TARGET_REVISION=main
```

Create a `.env.local` file for personal overrides (gitignored).

## Repository Structure

```
local-dc/
├── compose.yaml                      # Podman Compose — datacenter definition
├── .env                              # Default configuration
├── setup.sh                          # Bootstrap script (containerized)
├── scripts/
│   ├── bootstrap.sh                  # k3s init (ArgoCD + root app)
│   └── import-backstage.sh           # Build & import Backstage image
├── ansible/                          # Native k3s install (alternative)
│   ├── inventory.yml
│   └── playbook.yml
├── gitops/
│   ├── apps/                         # ArgoCD App-of-Apps
│   │   ├── kubevirt.yaml
│   │   ├── cdi.yaml
│   │   ├── kubevirt-manager.yaml
│   │   ├── keycloak.yaml
│   │   ├── backstage.yaml
│   │   ├── monitoring.yaml
│   │   ├── harbor.yaml
│   │   └── vms.yaml
│   ├── argocd/                       # ArgoCD install + OIDC config
│   ├── backstage/                    # Backstage deployment (platform ns)
│   ├── keycloak/                     # Keycloak deployment + realm config
│   ├── kubevirt/                     # KubeVirt operator + CR
│   ├── cdi/                          # CDI operator + CR
│   ├── kubevirt-manager/             # VM dashboard + NodePort patch
│   └── vms/                          # Developer VMs (developers ns)
├── backstage/                        # Backstage app source + Dockerfile
├── backstage-templates/              # Scaffolder templates + org catalog
│   ├── org.yaml
│   ├── ubuntu-vm.yaml
│   └── linuxmint-vm.yaml
└── datacenter.yaml                   # Lima config (macOS development)
```

## GitOps Workflow

All cluster changes flow through Git:

```
Edit gitops/ files → git commit → git push → ArgoCD syncs → Cluster updated
```

**Rules:**
- Never use `kubectl apply/patch/delete` for managed resources
- `kubectl get/logs/describe` is allowed for troubleshooting
- All infrastructure changes go through Git commits
- ArgoCD auto-syncs every 3 minutes (or force with refresh annotation)

## Native Install (Alternative)

For users who prefer k3s installed directly on the host (without containers):

```bash
# Install Ansible if needed
sudo apt-get install -y ansible

# Run the playbook
sudo ansible-playbook -i ansible/inventory.yml ansible/playbook.yml --become
```

This installs k3s natively, configures ArgoCD, and sets up the full GitOps pipeline on the host OS.

## Backstage Plugins

The custom Backstage image includes:

- **Auth**: GitHub OAuth, OIDC (Keycloak), Guest
- **Catalog**: Software catalog with search
- **Scaffolder**: Templates with GitHub actions
- **Kubernetes**: Cluster resource visibility
- **TechDocs**: Documentation-as-code
- **Notifications**: In-app notifications
- **MCP Actions**: AI-assisted actions

## Adding a New Engineer

1. Add the user to `backstage-templates/org.yaml`
2. Add the user to `gitops/keycloak/realm-configmap.yaml`
3. Commit and push
4. ArgoCD syncs the org catalog; Keycloak pod restart imports the realm

## Supported Distros

The setup script checks for Podman and `/dev/kvm`. Any Linux distro that provides these will work:
- **Ubuntu/Debian** — `sudo apt-get install -y podman podman-compose`
- **Fedora** — `sudo dnf install -y podman podman-compose`
- **Bazzite / Fedora Atomic** — Podman is pre-installed

## License

MIT
