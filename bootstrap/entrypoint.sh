#!/bin/sh
# Datacenter-in-a-Box — bootstrapper
# Runs once after the k3s API is healthy:
#   1. installs ArgoCD (from gitops/argocd, incl. OIDC + NodePort patches)
#   2. creates the root App-of-Apps, which makes ArgoCD sync the whole DC from Git
#
# This replaces the imperative kubectl/ansible steps from the old bare-metal path.
set -eu

KUBECONFIG_SRC=/output/kubeconfig.yaml
KCFG=/tmp/kubeconfig.yaml
REPO_URL="${REPO_URL:-https://github.com/stevebestone/local-dc.git}"
TARGET_REV="${TARGET_REV:-main}"

log() { echo "[bootstrap] $*"; }

log "waiting for kubeconfig at ${KUBECONFIG_SRC} ..."
while [ ! -f "$KUBECONFIG_SRC" ]; do sleep 2; done

# The host-facing kubeconfig points at 127.0.0.1; from this sidecar the API is
# reachable as 'server' over the compose network (covered by --tls-san=server).
sed 's#https://127.0.0.1:6443#https://server:6443#' "$KUBECONFIG_SRC" > "$KCFG"
export KUBECONFIG="$KCFG"

log "waiting for the API server to report ready ..."
until k3s kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 3; done

log "waiting for the node to become Ready ..."
until k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 3; done

if ! k3s kubectl get namespace argocd >/dev/null 2>&1; then
  log "installing ArgoCD ..."
  k3s kubectl apply -k /gitops/argocd --server-side
  log "waiting for argocd-server rollout ..."
  k3s kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
else
  log "ArgoCD already present, skipping install."
fi

log "applying root App-of-Apps (repo=${REPO_URL} rev=${TARGET_REV}) ..."
cat <<EOF | k3s kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REV}
    path: gitops/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

log "done — ArgoCD is now syncing the datacenter from Git."
log "If you use a custom Backstage image, run:  make backstage"
