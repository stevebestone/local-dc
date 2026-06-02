output "argocd_url" {
  description = "ArgoCD web UI URL"
  value       = "http://${var.host_ip}:30082"
}

output "argocd_admin_password_command" {
  description = "Command to retrieve the ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
}

output "kubeconfig_path" {
  description = "Path to the k3s kubeconfig"
  value       = var.kubeconfig_path
}

output "web_uis" {
  description = "Service URLs (available after ArgoCD sync completes)"
  value = {
    argocd           = "http://${var.host_ip}:30082"
    backstage        = "http://${var.host_ip}:30081"
    keycloak         = "http://${var.host_ip}:30083"
    grafana          = "http://${var.host_ip}:30084"
    harbor           = "http://${var.host_ip}:30085"
    kubevirt_manager = "http://${var.host_ip}:30080"
  }
}
