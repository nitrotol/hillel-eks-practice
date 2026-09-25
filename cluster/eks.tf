# ---------------------------------------------------------------------------
# Кластер EKS.
#
# Вартість: контрольний рівень $0.10/год ($73 на місяць) незалежно ні від чого —
# навіть якщо вузлів нуль і подів нуль. Саме тому між заняттями ми опускаємо
# вузли в нуль (командою aws eks update-nodegroup-config, див. README), а не
# видаляємо кластер: перестворення контрольного рівня триває 9-12 хвилин щоразу.
# ---------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # Сервер API доступний з інтернету. Інакше знадобився б бастіон або VPN.
  endpoint_public_access  = true
  endpoint_private_access = true

  # Той, хто створив кластер, одразу отримує права адміністратора в ньому.
  # УВАГА: «той, хто створив» — це роль HCP Terraform, а НЕ ви.
  # Саме тому нижче є окремий блок access_entries для вашого користувача.
  enable_cluster_creator_admin_permissions = true

  # -------------------------------------------------------------------------
  # Доступ людей до кластера.
  # Access entries прив'язують обліковий запис IAM до прав у кластері.
  # Кожен ARN зі змінної cluster_admin_arns отримує права адміністратора.
  # -------------------------------------------------------------------------
  access_entries = {
    for i, arn in var.cluster_admin_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  vpc_id = module.vpc.vpc_id

  # Вузли у публічних підмережах — див. пояснення у vpc.tf
  subnet_ids = module.vpc.public_subnets

  # -------------------------------------------------------------------------
  # Доповнення EKS: компоненти, які AWS постачає, версіонує й оновлює
  # як частину сервісу. Порожні {} означають версію за замовчуванням
  # для цієї версії Kubernetes.
  # -------------------------------------------------------------------------
  addons = {
    # Мережевий плагін має бути налаштований ДО появи вузлів,
    # інакше перші поди отримають не ті адреси. Це реальна залежність
    # порядку, а не декоративний прапорець.
    vpc-cni = {
      before_compute = true

      # ---------------------------------------------------------------------
      # Prefix delegation — як у продакшні знімають ліміт подів на вузлі.
      #
      # За замовчуванням кожен под отримує одну адресу з VPC, а кількість
      # адрес на машині обмежена її мережевими інтерфейсами (29 для
      # c7i-flex.large). З prefix delegation кожен слот інтерфейсу отримує
      # не одну адресу, а цілий блок /28 — шістнадцять адрес.
      #
      # WARM_PREFIX_TARGET — скільки вільних блоків тримати напоготові,
      # щоб нові поди не чекали на виділення адрес.
      #
      # Для КЕРОВАНОЇ групи вузлів цього досить: EKS сам перерахує ліміт
      # подів на вузлі з урахуванням prefix delegation. Окремо задавати maxPods
      # потрібно лише для self-managed вузлів, власних AMI або Karpenter.
      #
      # Працює лише на машинах Nitro (усі сучасні типи, включно з нашими)
      # і має бути ввімкнено ДО появи вузлів — саме тому before_compute.
      # Вузли, створені раніше, треба перестворити, інакше вони покажуть
      # старий ліміт.
      # ---------------------------------------------------------------------
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }

    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}

    # Драйверу дисків потрібен доступ до AWS: він створює й підключає томи EBS
    # на вимогу PersistentVolumeClaim. Роль прив'язується до службового акаунта.
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # -------------------------------------------------------------------------
  # Група вузлів.
  # Тип машини й модель оплати — у змінних, з поясненням обмежень Free plan.
  # -------------------------------------------------------------------------
  eks_managed_node_groups = {
    main = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      # min_size = 0 — саме це дозволяє опускати кластер у нуль
      # між заняттями, не видаляючи його.
      min_size = 0
      max_size = 3

      # Лише початкове значення: модуль ігнорує подальші зміни desired_size.
      desired_size = var.node_desired_size

      disk_size = 20

      labels = {
        workload = "general"
      }

      tags = local.common_tags
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Роль для драйвера дисків EBS.
#
# Драйвер створює й підключає томи EBS на вимогу PersistentVolumeClaim,
# тому йому потрібен доступ до AWS. Дає його роль, прив'язана до службового
# акаунта через Pod Identity — под не зберігає жодного ключа.
#
# ВАЖЛИВО ПРО ПОЛІТИКУ ДОВІРИ:
# для Pod Identity роль довіряє СЕРВІСУ pods.eks.amazonaws.com.
# Це відрізняється від старшого механізму IRSA, де роль довіряла
# OIDC-провайдеру кластера. Плутанина між ними — часта причина помилки
# "is not authorized to perform: sts:AssumeRole".
#
# Друга відмінність: окрім sts:AssumeRole потрібна ще й sts:TagSession.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.prefix}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json

  tags = local.common_tags
}

# Готова керована політика від AWS саме для цього драйвера.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
