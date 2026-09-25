# ---------------------------------------------------------------------------
# Заняття 10. Друга синхронізація Flux — для інфраструктури кластера.
#
# Тека infrastructure/ у корені репозиторію описує компоненти, які потрібні
# застосункам: контролер балансувальників і External Secrets Operator.
# Flux ставить їх так само, як застосунок: коміт у git -> зміна в кластері.
#
# Чому окрема синхронізація, а не ще одна тека в apps/shop:
#   1) інфраструктура має бути готова РАНІШЕ за застосунок (dependsOn у flux.tf);
#   2) тут потрібні значення, яких немає в git: ім'я кластера, VPC, регіон.
#
# Той самий чарт flux2-sync, що й для застосунку. Він створює ще один
# GitRepository на той самий репозиторій — трохи зайвої роботи для
# source-controller, зате жодного нового інструмента.
# ---------------------------------------------------------------------------
resource "helm_release" "infra_sync" {
  name       = "infra-sync"
  repository = "https://fluxcd-community.github.io/helm-charts"
  chart      = "flux2-sync"
  version    = "1.15.1"
  namespace  = "flux-system"

  # Асоціації Pod Identity мають існувати ДО того, як Flux запустить поди
  # контролерів: под отримує облікові дані лише на старті.
  depends_on = [
    helm_release.flux,
    aws_eks_pod_identity_association.lbc,
    aws_eks_pod_identity_association.eso,
  ]

  values = [yamlencode({
    gitRepository = {
      spec = {
        url      = var.git_url
        interval = var.sync_interval
        ref = {
          branch = var.git_branch
        }
      }
    }

    kustomization = {
      spec = {
        path     = "./infrastructure"
        interval = var.sync_interval
        prune    = true

        # wait: Kustomization стає Ready лише тоді, коли всі її об'єкти
        # здорові — зокрема обидва HelmRelease встановились. Саме на цей
        # стан чекає dependsOn застосунку.
        wait    = true
        timeout = "5m"

        # МІСТ МІЖ TERRAFORM І FLUX.
        # Terraform знає факти про AWS, яких немає в git. Він передає їх
        # у Flux, а Flux перед застосуванням підставляє їх у маніфести
        # на місце ${CLUSTER_NAME}, ${VPC_ID}, ${AWS_REGION}.
        # Так у репозиторії немає нічого, прив'язаного до вашого акаунта,
        # і вам не треба нічого вписувати руками.
        postBuild = {
          substitute = {
            CLUSTER_NAME = module.eks.cluster_name
            VPC_ID       = module.vpc.vpc_id
            AWS_REGION   = var.region
          }
        }
      }
    }
  })]
}
