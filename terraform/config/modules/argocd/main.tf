resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  lifecycle {
    ignore_changes = [metadata]
  }
}

resource "helm_release" "argocd" {
  depends_on = [kubernetes_namespace.argocd]

  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  wait       = true
  timeout    = 600

  values = [<<YAML
configs:
  params:
    server.insecure: "true"
server:
  service:
    type: ClusterIP
YAML
  ]
}

// ApplicationSet: manages Helm+Git multi-source applications
resource "kubernetes_manifest" "core_helm_appset" {
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "ApplicationSet"
    metadata = {
      name      = "core-helm-apps"
      namespace = "argocd"
    }
    spec = {
      generators = [
        {
          git = {
            repoURL  = var.git_url
            revision = var.git_revision
            files    = [{ path = "gitops/core/apps/helm/*/config.yaml" }]
          }
        }
      ]
      template = {
        metadata = {
          name      = "{{appName}}"
          namespace = "argocd"
        }
        spec = {
          project = "default"
          sources = [
            {
              repoURL        = "{{helmRepoURL}}"
              chart          = "{{chart}}"
              targetRevision = "{{chartVersion}}"
              helm = {
                valueFiles = ["$values/{{gitPath}}/values.yaml"]
              }
            },
            {
              repoURL        = var.git_url
              targetRevision = var.git_revision
              path           = "{{gitPath}}"
              ref            = "values"
            }
          ]
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "{{namespace}}"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
            syncOptions = ["CreateNamespace=true", "ServerSideApply=true"]
          }
        }
      }
    }
  }
}

// ApplicationSet: manages Git-only applications (no Helm chart)
resource "kubernetes_manifest" "core_gitonly_appset" {
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "ApplicationSet"
    metadata = {
      name      = "core-gitonly-apps"
      namespace = "argocd"
    }
    spec = {
      generators = [
        {
          git = {
            repoURL  = var.git_url
            revision = var.git_revision
            files    = [{ path = "gitops/core/apps/gitonly/*/config.yaml" }]
          }
        }
      ]
      template = {
        metadata = {
          name      = "{{appName}}"
          namespace = "argocd"
          annotations = {
            "argocd.argoproj.io/sync-wave" = "{{syncWave}}"
          }
        }
        spec = {
          project = "default"
          source = {
            repoURL        = var.git_url
            targetRevision = var.git_revision
            path           = "{{gitPath}}"
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "{{namespace}}"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
            syncOptions = ["CreateNamespace=true"]
          }
        }
      }
    }
  }
}
