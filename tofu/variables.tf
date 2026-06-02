variable "kubeconfig_path" {
  description = "Path to the k3s kubeconfig file"
  type        = string
  default     = "/etc/rancher/k3s/k3s.yaml"
}

variable "repo_url" {
  description = "Git repository URL for ArgoCD to sync from"
  type        = string
  default     = "https://github.com/stevebestone/local-dc.git"
}

variable "target_revision" {
  description = "Git branch or tag for ArgoCD to track"
  type        = string
  default     = "main"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "7.8.13"
}

variable "host_ip" {
  description = "Host IP address for service URLs (used in OIDC config)"
  type        = string
  default     = "localhost"
}
