variable "git_url" {
  description = "Git repository URL for ArgoCD to sync from"
  type        = string
  nullable    = false
}

variable "git_revision" {
  description = "Git branch or tag to sync"
  type        = string
  default     = "HEAD"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "7.8.26"
}
