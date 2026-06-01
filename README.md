# Local DC — Datacenter-in-a-Box

A fully GitOps-managed local datacenter running on bare-metal Linux, powered by k3s, KubeVirt, ArgoCD, Backstage, and Keycloak.

Engineers self-provision development VMs through the Backstage Developer Portal. All infrastructure is declared in Git and synced by ArgoCD.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Bare-Metal Intel i9 — Linux  (host /dev/kvm)           │
│                                                         │
│  podman compose up                                      │
│  ┌─── rancher/k3s container (privileged) ────────────┐  │
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
│  └─── kvm passthrough → KubeVirt runs real VMs ─────┘  │
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

- Linux host (Ubuntu, Fedora, or Bazzite) with an Intel/AMD CPU
- VT-x/AMD-V enabled in BIOS and `/dev/kvm` available (`ls -l /dev/kvm`)
- **Podman** with the `podman compose` provider (or `podman-compose`) and `make`
- At least 16 GB RAM (32 GB+ recommended for several VMs)

> **Run rootful.** In-container kubelet plus `/dev/kvm` passthrough is only reliable
> under rootful Podman — use `sudo -E podman compose ...` or a rootful `podman machine`.
> Rootless privileged + KVM is finicky and not supported here.

### Install

```bash
git clone https://github.com/stevebestone/local-dc.git
cd local-dc
cp .env.example .env          # optional: pin k3s tag / point at a branch
make up                       # == sudo -E podman compose up -d
make logs                     # watch the bootstrapper finish
```

`make up` (`podman compose up`):
1. Starts a privileged `rancher/k3s` container — Kubernetes running **inside a container**,
   with the host's `/dev/kvm` passed through for KubeVirt.
2. Runs a one-shot bootstrapper that installs ArgoCD and the root App-of-Apps.
3. ArgoCD then syncs the rest from Git: KubeVirt, CDI, KubeVirt Manager, Keycloak,
   Backstage, monitoring, and Harbor.

```bash
make status        # containers + nodes + ArgoCD apps
make verify        # confirm /dev/kvm reached the node (no slow software emulation)
eval "$(make -s kubeconfig)"   # point host kubectl/virtctl at the cluster
```

### Teardown

```bash
make down          # stop the DC — cluster state + pulled images are kept for a fast restart
make wipe          # full reset: podman compose down -v + remove kubeconfig
```

### Build Custom Backstage Image

The custom Backstage image includes GitHub OAuth, OIDC (Keycloak), Kubernetes, TechDocs, and other plugins. `make backstage` builds it and loads it straight into the containerized node's image store (the Deployment uses `imagePullPolicy: Never`):

```bash
# Install build dependencies (one-time)
sudo apt-get install -y python3 g++ build-essential libsqlite3-dev

# Build + import into the running node
make backstage
```

Under the hood this builds with Podman, then `podman cp`s the image tar into the
`server` container and imports it with `k3s ctr -n k8s.io images import`.

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
├── compose.yaml                      # The datacenter emulator (podman compose up/down)
├── .env.example                      # k3s tag, ports, GitOps source overrides
├── Makefile                          # up / down / wipe / status / backstage / verify
├── bootstrap/
│   └── entrypoint.sh                 # waits for k3s → installs ArgoCD → root App-of-Apps
├── gitops/
│   ├── apps/                         # ArgoCD App-of-Apps
│   │   ├── kubevirt.yaml
│   │   ├── cdi.yaml
│   │   ├── kubevirt-manager.yaml
│   │   ├── keycloak.yaml
│   │   ├── backstage.yaml
│   │   └── vms.yaml
│   ├── argocd/                       # ArgoCD install + OIDC + NodePort patches
│   ├── backstage/                    # Backstage deployment (platform ns)
│   ├── keycloak/                     # Keycloak deployment + realm config
│   ├── kubevirt/                     # KubeVirt operator + CR
│   ├── cdi/                          # CDI operator + CR
│   ├── kubevirt-manager/             # VM dashboard + NodePort patch
│   └── vms/                          # Developer VMs (developers ns)
├── backstage/                        # Backstage app source + Dockerfile
├── backstage-templates/              # Scaffolder templates + org catalog
│   ├── org.yaml                      # Users and groups
│   ├── ubuntu-vm.yaml                # Ubuntu VM template
│   └── linuxmint-vm.yaml            # Linux Mint VM template
└── datacenter.yaml                   # Optional Lima VM for macOS hosts (see note below)
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

## Supported Hosts

The k3s cluster runs as a **container**, so there is no host mutation — no native k3s
service, no removed packages. Any Linux host with Podman and `/dev/kvm` works:

- **Ubuntu / Debian**, **Fedora**, **Bazzite / Fedora Atomic**

For best VM performance, ensure the KVM and vhost modules are loaded on the host:

```bash
sudo modprobe kvm vhost_net
```

### macOS note

`datacenter.yaml` is an optional Lima VM for macOS hosts. Apple Silicon has **no
`/dev/kvm`**, so KubeVirt there falls back to slow software emulation — the
containerized path above is intended for the Linux/i9 host. On macOS, run the Lima VM
and use it as a Linux host for the same workflow.

## License

MIT
