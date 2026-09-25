# ---------------------------------------------------------------------------
# Заняття 10. Скопіюйте в cluster/ разом з усією текою:
#   cp -r lessons/10-traffic-secrets/. cluster/
#
# Доступ до AWS для двох компонентів кластера.
#
# МЕЖА ВІДПОВІДАЛЬНОСТІ:
#   Terraform (цей файл) — усе, що живе в AWS: ролі, політики, асоціації
#                          Pod Identity. Terraform знає акаунт, регіон, ARN.
#   Flux (тека infrastructure/ у корені репозиторію) — самі компоненти
#                          всередині кластера:
#                          чарти Helm, їхні налаштування.
#
# Механізм той самий, що в драйвера дисків EBS на занятті 8:
#   роль довіряє сервісу pods.eks.amazonaws.com  ->  асоціація прив'язує роль
#   до службового акаунта (namespace + ім'я)     ->  под із цим акаунтом
#   отримує тимчасові облікові дані. Жодного ключа в кластері.
#
# Різниця лише в тому, що для EBS асоціацію створював модуль EKS (бо це
# доповнення EKS), а тут ми створюємо її явно ресурсом
# aws_eks_pod_identity_association — бо ці компоненти ставить не AWS, а Flux.
# ---------------------------------------------------------------------------

# Політика довіри, спільна для обох ролей.
# Дві дії, а не одна: Pod Identity окрім AssumeRole ставить на сесію теги
# (ім'я кластера, namespace, службовий акаунт) — для цього потрібен TagSession.
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ===========================================================================
# 1. AWS Load Balancer Controller
#    Створює балансувальники NLB для сервісів типу LoadBalancer.
# ===========================================================================

resource "aws_iam_role" "lbc" {
  name               = "${var.prefix}-lbc"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = local.common_tags
}

# Політику НЕ пишемо самі: її публікують автори контролера, і вона змінюється
# разом із версією. Файл узято з репозиторію контролера для версії v3.5.0:
#   https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.5.0/docs/install/iam_policy.json
# Оновлюєте контролер — оновлюйте й цей файл, інакше нова версія може
# впертися в AccessDenied на дії, якої старій політиці не вистачає.
resource "aws_iam_policy" "lbc" {
  name   = "${var.prefix}-lbc"
  policy = file("${path.module}/policies/aws-load-balancer-controller-v3.5.0.json")

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# namespace і service_account мають ТОЧНО збігатися з тим, що створить чарт.
# Тому в infrastructure/aws-load-balancer-controller.yaml ім'я службового
# акаунта задане явно, а не згенероване чартом.
resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn

  tags = local.common_tags
}

# ===========================================================================
# 2. External Secrets Operator
#    Читає параметри з SSM Parameter Store і створює з них Secret у кластері.
# ===========================================================================

data "aws_caller_identity" "platform" {}

# Мінімальні права: лише ЧИТАННЯ і лише параметрів під шляхом /shop/.
# Параметр /shop/banner має ARN ...:parameter/shop/banner — перша коса риска
# зі шляху в ARN не потрапляє.
#
# kms:Decrypt тут не потрібен: параметри SecureString ми шифруємо ключем,
# яким керує AWS (aws/ssm). Для власного ключа KMS знадобився б і він.
data "aws_iam_policy_document" "eso_read_shop_parameters" {
  statement {
    sid    = "ReadShopParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.platform.account_id}:parameter/shop/*",
    ]
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.prefix}-eso"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = local.common_tags
}

# Вбудована політика: вона має сенс лише разом із цією роллю,
# тож окремий об'єкт політики не потрібен.
resource "aws_iam_role_policy" "eso" {
  name   = "read-shop-parameters"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso_read_shop_parameters.json
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Що перевірити після apply (у CloudShell):
#   aws eks list-pod-identity-associations --cluster-name <prefix>-eks
# Має бути три асоціації: ebs-csi-controller-sa, aws-load-balancer-controller,
# external-secrets.
# ---------------------------------------------------------------------------
output "pod_identity_roles" {
  description = "Ролі, які отримують поди компонентів через Pod Identity."
  value = {
    load_balancer_controller = aws_iam_role.lbc.arn
    external_secrets         = aws_iam_role.eso.arn
  }
}
