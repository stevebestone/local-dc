# ─── ArgoCD namespace ────────────────────────────────────
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

# ─── ArgoCD Helm release ────────────────────────────────
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  wait       = true
  timeout    = 600

  # ── Server: NodePort on 30082 ──
  set {
    name  = "server.service.type"
    value = "NodePort"
  }
  set {
    name  = "server.service.nodePortHttp"
    value = "30082"
  }

  # ── OIDC (Keycloak) ──
  set {
    name  = "configs.cm.url"
    value = "http://localhost:30082"
  }
  set {
    name  = "configs.cm.oidc\\.config"
    value = yamlencode({
      name         = "Keycloak"
      issuer       = "http://${var.host_ip}:30083/realms/local-dc"
      clientID     = "argocd"
      clientSecret = "$oidc.keycloak.clientSecret"
      requestedScopes = ["openid", "profile", "email", "groups"]
    })
  }

  # ── RBAC ── (use values block: commas in CSV break Helm --set parsing)
  values = [
    yamlencode({
      configs = {
        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv"     = "g, admins, role:admin\ng, engineers, role:readonly"
        }
      }
    })
  ]

  # ── Health check: track child Application health for sync-waves ──
  set {
    name  = "configs.cm.resource\\.customizations\\.health\\.argoproj\\.io_Application"
    value = <<-LUA
      hs = {}
      hs.status = "Progressing"
      hs.message = ""
      if obj.status ~= nil then
        if obj.status.health ~= nil then
          hs.status = obj.status.health.status
          if obj.status.health.message ~= nil then
            hs.message = obj.status.health.message
          end
        end
      end
      return hs
    LUA
  }

  # ── Run in insecure (plain HTTP) mode so configs.cm.url matches how the
  #    browser accesses ArgoCD. Without this ArgoCD redirects HTTP→HTTPS,
  #    but configs.cm.url is http://, causing OIDC redirect URL mismatch. ──
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  # ── Disable components not needed for single-node ──
  set {
    name  = "dex.enabled"
    value = "false"
  }
  set {
    name  = "notifications.enabled"
    value = "false"
  }
  set {
    name  = "applicationSet.enabled"
    value = "false"
  }
}
