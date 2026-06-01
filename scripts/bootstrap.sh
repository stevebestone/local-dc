#!/bin/sh
#
# Local DC — Bootstrap Script
# Runs inside the bootstrap container after k3s is healthy.
# Installs ArgoCD and creates the root App-of-Apps.
#
set -e

echo "═══════════════════════════════════════════════════"
echo " LOCAL DC — Bootstrap"
echo "═══════════════════════════════════════════════════"

# ─── Kubeconfig ─────────────────────────────────────────
echo "Configuring kubeconfig..."
cp /output/kubeconfig.yaml /tmp/kubeconfig.yaml
sed -i 's|127\.0\.0\.1|k3s-server|g' /tmp/kubeconfig.yaml

# Verify connectivity
echo "Verifying k3s API connectivity..."
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  echo "  Waiting for k3s API..."
  sleep 5
done
echo "✓ k3s is ready"
kubectl get nodes

# ─── ArgoCD ─────────────────────────────────────────────
if kubectl get namespace argocd >/dev/null 2>&1; then
  echo "✓ ArgoCD namespace already exists — skipping install"
else
  echo "Installing ArgoCD..."
  kubectl kustomize /gitops/argocd | kubectl apply --server-side -f -

  echo "Waiting for ArgoCD server..."
  kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
  echo "✓ ArgoCD is ready"
fi

# Expose ArgoCD on NodePort 30082
kubectl -n argocd patch svc argocd-server --type='json' \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},
       {"op":"replace","path":"/spec/ports/0/nodePort","value":30082}]' 2>/dev/null || true

# ─── Root App-of-Apps ───────────────────────────────────
if kubectl get application root-apps -n argocd >/dev/null 2>&1; then
  echo "✓ Root App-of-Apps already exists — skipping"
else
  echo "Creating root App-of-Apps..."
  echo "  Repo:     ${REPO_URL}"
  echo "  Revision: ${TARGET_REVISION}"

  cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: gitops/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
  echo "✓ Root App-of-Apps created"
fi

# ─── Summary ────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " BOOTSTRAP COMPLETE"
echo "═══════════════════════════════════════════════════"
echo ""
echo " ArgoCD is now syncing all components from Git."
echo " This may take 5-10 minutes for all pods to start."
echo ""
echo " Web UIs (available after sync):"
echo "   ArgoCD:           http://localhost:30082"
echo "   KubeVirt Manager: http://localhost:30080"
echo "   Backstage:        http://localhost:30081"
echo "   Keycloak:         http://localhost:30083"
echo "   Grafana:          http://localhost:30084"
echo "   Harbor:           http://localhost:30085"
echo ""
echo " To get the ArgoCD admin password, run:"
echo "   podman exec local-dc-k3s-server-1 kubectl -n argocd \\"
echo "     get secret argocd-initial-admin-secret \\"
echo "     -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "═══════════════════════════════════════════════════"
