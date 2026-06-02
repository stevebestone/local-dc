# Local DC — Datacenter-in-a-Box

A fully GitOps-managed local datacenter running on bare-metal Linux, powered by k3s, KubeVirt, ArgoCD, Backstage, and Keycloak.

Engineers self-provision development VMs through the Backstage Developer Portal. All infrastructure is declared in Git and synced by ArgoCD.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Bare-Metal Intel i9 — Ubuntu Linux                     │
│                                                         │
│  ┌─── k3s (Kubernetes) ──────────────────────────────┐  │
│  │                                                   │  │
│  │  argocd        → ArgoCD (GitOps controller)       │  │
│  │  platform      → Backstage IDP + KubeVirt Manager │  │
│  │  keycloak      → Keycloak IAM (OIDC provider)     │  │
│  │  kubevirt      → KubeVirt operator                │  │
│  │  cdi           → Containerized Data Importer      │  │
│  │  developers    → Engineer VMs (KubeVirt)          │  │
│  │                                                   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  Git repo ──→ ArgoCD ──→ All cluster resources          │
│  Engineer  ──→ Backstage ──→ VM provisioning            │
│  Auth      ──→ Keycloak OIDC ──→ All applications      │
│  Metrics   ──→ Prometheus ──→ Grafana dashboards        │
│  Images    ──→ Harbor container registry                 │
└─────────────────────────────────────────────────────────┘
```

## Components

| Component | Version | Namespace | Description |
|-----------|---------|-----------|-------------|
| k3s | v1.35.5 | — | Lightweight Kubernetes |
| ArgoCD | stable | `argocd` | GitOps continuous delivery |
| KubeVirt | v1.8.2 | `kubevirt` | VM management on Kubernetes |
| CDI | v1.65.0 | `cdi` | VM disk image management |
| KubeVirt Manager | latest | `platform` | Web UI for VM operations |
| Backstage | 1.51 (custom) | `platform` | Internal Developer Portal |
| Keycloak | 26.0 | `keycloak` | Identity & Access Management |
| Prometheus | latest | `monitoring` | Metrics collection (7-day retention) |
| Grafana | latest | `monitoring` | Monitoring dashboards |
| Harbor | latest | `harbor` | Container/artifact registry |

## Web UIs

| Service | URL | Auth |
|---------|-----|------|
| **Backstage** (Developer Portal) | `http://<node-ip>:30081` | Keycloak OIDC / Guest |
| **ArgoCD** (GitOps Dashboard) | `http://<node-ip>:30082` | Keycloak OIDC |
| **Keycloak** (IAM Admin) | `http://<node-ip>:30083` | admin / admin |
| **Grafana** (Monitoring) | `http://<node-ip>:30084` | admin / (see secret) |
| **Harbor** (Container Registry) | `http://<node-ip>:30085` | Keycloak OIDC |
| **KubeVirt Manager** (VM Dashboard) | `http://<node-ip>:30080` | No auth |

## Quick Start

### Prerequisites

- Bare-metal Linux (Ubuntu, Fedora, or Bazzite) with Intel/AMD CPU
- VT-x/AMD-V enabled in BIOS
- At least 16 GB RAM
- `/dev/kvm` available

### Install

```bash
git clone https://github.com/stevebestone/local-dc.git
cd local-dc
chmod +x setup.sh
sudo ./setup.sh
```

The setup script:
1. Checks prerequisites (VT-x, /dev/kvm)
2. Installs k3s natively
3. Installs OpenTofu and Helm (if not present)
4. Runs `tofu apply` to deploy ArgoCD (Helm chart) and the root App-of-Apps
5. Installs virtctl CLI

After setup, ArgoCD automatically deploys components in dependency order (sync-waves):

1. **Keycloak** — identity provider (OIDC for all services)
2. **Monitoring** — Prometheus + Grafana
3. **Harbor** — container registry
4. **KubeVirt + CDI** — virtualization platform
5. **KubeVirt Manager + VMs** — VM dashboard and manifests
6. **Backstage** — developer portal (last, depends on everything)

### Lifecycle

```bash
# View cluster status
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get pods -A

# Tear down ArgoCD + apps (keeps k3s)
tofu -chdir=tofu destroy

# Uninstall k3s entirely
/usr/local/bin/k3s-uninstall.sh
```

### Build Custom Backstage Image

The custom Backstage image includes GitHub OAuth, OIDC (Keycloak), Kubernetes, TechDocs, and other plugins.

```bash
# Build and import into k3s (requires Podman or Docker)
./scripts/import-backstage.sh

# Or manually:
podman build -t localhost/backstage-idp:latest -f backstage/Dockerfile backstage/
podman save localhost/backstage-idp:latest | sudo ctr -n k8s.io images import -
```

## Login Procedures

### Backstage (Developer Portal)

1. Open `http://<node-ip>:30081`
2. Choose login method:
   - **Guest**: Click "Enter" (no credentials, development mode)
   - **OIDC (Keycloak)**: Click "OIDC" → redirects to Keycloak login
3. Enter Keycloak credentials (see user table below)
4. First login requires password change

### ArgoCD

1. Open `http://<node-ip>:30082`
2. Login options:
   - **Keycloak**: Click "Log in via Keycloak" → use Keycloak credentials
   - **Local admin**: Username `admin`, password:
     ```bash
     kubectl -n argocd get secret argocd-initial-admin-secret \
       -o jsonpath='{.data.password}' | base64 -d && echo
     ```

### Keycloak Admin Console

1. Open `http://<node-ip>:30083`
2. Login: `admin` / `admin`
3. Select realm: `local-dc`

### Harbor

1. Open `http://<node-ip>:30085`
2. Click **"LOGIN VIA OIDC PROVIDER"**
3. Keycloak login page → enter credentials
4. Users in `admins` group get Harbor admin access

### Grafana

1. Open `http://<node-ip>:30084`
2. Username: `admin`, password:
   ```bash
   kubectl -n monitoring get secret monitoring-grafana \
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
sudo ./secrets/create-secrets.sh

# With custom passwords
PLATFORM_ADMIN_PASSWORD=... KC_ADMIN_PASSWORD=... sudo -E ./secrets/create-secrets.sh
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
# List all VMs
kubectl get vm,vmi -n developers

# Start / Stop / Restart
virtctl start <vm-name> -n developers
virtctl stop <vm-name> -n developers
virtctl restart <vm-name> -n developers

# Console access
virtctl console <vm-name> -n developers    # serial
virtctl vnc <vm-name> -n developers        # graphical
```

## Repository Structure

```
local-dc/
├── setup.sh                          # Bootstrap: k3s install + tofu apply
├── tofu/                             # OpenTofu IaC (ArgoCD + App-of-Apps)
│   ├── versions.tf                   # Required providers
│   ├── variables.tf                  # Inputs (kubeconfig, repo, host IP)
│   ├── providers.tf                  # Kubernetes + Helm providers
│   ├── argocd.tf                     # ArgoCD Helm release + OIDC/RBAC config
│   ├── apps.tf                       # Root App-of-Apps
│   └── outputs.tf                    # URLs and credential commands
├── scripts/
│   └── import-backstage.sh           # Build + import Backstage image
├── ansible/                          # Alternative: Ansible-based bootstrap
│   ├── inventory.yml
│   └── playbook.yml
├── gitops/
│   ├── apps/                         # ArgoCD App-of-Apps (sync-wave ordered)
│   │   ├── keycloak.yaml             # Wave 10
│   │   ├── monitoring.yaml           # Wave 20
│   │   ├── harbor.yaml               # Wave 30
│   │   ├── kubevirt.yaml             # Wave 40
│   │   ├── cdi.yaml                  # Wave 40
│   │   ├── kubevirt-manager.yaml     # Wave 50
│   │   ├── vms.yaml                  # Wave 50
│   │   └── backstage.yaml            # Wave 60
│   ├── argocd/                       # ArgoCD namespace
│   ├── backstage/                    # Backstage deployment (platform ns)
│   ├── keycloak/                     # Keycloak deployment + realm config
│   ├── kubevirt/                     # KubeVirt operator + CR
│   ├── cdi/                          # CDI operator + CR
│   ├── kubevirt-manager/             # VM dashboard + NodePort patch
│   └── vms/                          # Developer VMs (developers ns)
├── backstage/                        # Backstage app source + Dockerfile
└── backstage-templates/              # Scaffolder templates + org catalog
    ├── org.yaml                      # Users and groups
    ├── ubuntu-vm.yaml                # Ubuntu VM template
    └── linuxmint-vm.yaml             # Linux Mint VM template
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

The setup script requires:
- **Linux** with VT-x/AMD-V and `/dev/kvm`
- **curl** (installed automatically if missing)

Tested on Ubuntu. Other distros (Fedora, Bazzite) should work via the Ansible alternative:
```bash
sudo ansible-playbook -i ansible/inventory.yml ansible/playbook.yml --become
```

## License

MIT
