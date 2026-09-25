variable "prefix" {
  description = "Префікс імен усіх ресурсів. Поставте своє прізвище: усі студенти в одному регіоні."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.prefix))
    error_message = "Префікс: лише малі літери, цифри й дефіс, від 3 до 20 символів."
  }
}

variable "region" {
  description = "Регіон AWS."
  type        = string
  default     = "eu-central-1"
}

variable "kubernetes_version" {
  description = <<-EOT
    Версія Kubernetes. Закріплена навмисно.
    УВАГА: версія, що вийшла зі стандартної підтримки (14 місяців), коштує $0.60/год
    замість $0.10 — це $438 на місяць замість $73. Перевіряйте раз на півроку.
  EOT
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "Діапазон адрес VPC."
  type        = string
  default     = "10.30.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr має бути коректним записом CIDR, наприклад 10.30.0.0/16."
  }
}

variable "node_desired_size" {
  description = <<-EOT
    Скільки вузлів створити РАЗОМ ІЗ ГРУПОЮ.

    УВАГА: діє лише при створенні групи вузлів. Модуль EKS тримає desired_size
    в ignore_changes, щоб Terraform не відкочував рішення автомасштабувальника,
    тому пізніша зміна цієї змінної кількість вузлів НЕ змінює.
    Піднімати й опускати вузли між заняттями — командою AWS CLI, див. README,
    розділ «Режим життя кластера».
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.node_desired_size >= 0 && var.node_desired_size <= 3
    error_message = "Від 0 до 3. Більше для навчального кластера не потрібно."
  }
}

variable "node_instance_types" {
  description = <<-EOT
    Типи машин для групи вузлів.

    ОБМЕЖЕННЯ FREE PLAN: на акаунтах, створених після 15.07.2025 на Free plan,
    дозволені лише t3.micro, t3.small, t4g.micro, t4g.small, c7i-flex.large,
    m7i-flex.large. Інші типи просто не запустяться.

    Чому саме ці два, а не t3.small: навіть із prefix delegation, яка знімає
    ліміт подів, EKS резервує під систему пам'ять пропорційно до ліміту подів
    на вузлі. На 2 GiB у t3.small після резерву майже нічого не лишається.
    Розрахунок — у README.

    Для spot потрібно кілька типів: AWS шукає вільну потужність серед усіх
    перелічених. Обидва мають 2 vCPU, тож бюджет рахуємо за меншим — c7i-flex.large.
  EOT
  type        = list(string)
  default     = ["c7i-flex.large", "m7i-flex.large"]

  validation {
    condition     = length(var.node_instance_types) >= 1
    error_message = "Вкажіть щонайменше один тип машини."
  }

  validation {
    condition     = !anytrue([for t in var.node_instance_types : contains(["t3.micro", "t4g.micro"], t)])
    error_message = "t3.micro і t4g.micro вміщають лише 4 поди — їх повністю займуть системні компоненти. Оберіть c7i-flex.large."
  }
}

variable "node_capacity_type" {
  description = <<-EOT
    SPOT або ON_DEMAND.

    За замовчуванням SPOT: у кілька разів дешевше за ту саму машину.

    УВАГА: ми НЕ змогли підтвердити в документації AWS, що spot працює на
    Free plan. Якщо вузол не піднімається й у подіях групи вузлів помилка про
    spot або квоту — поставте ON_DEMAND. Окремо перевірте квоту:
    для SPOT це "All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests",
    для ON_DEMAND — "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances".

    Spot-машину AWS може забрати з двохвилинним попередженням. З одним вузлом
    це означає коротку паузу, поки підніметься новий: для навчання прийнятно,
    для продакшну — ні.
  EOT
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "Лише ON_DEMAND або SPOT."
  }
}

variable "cluster_admin_arns" {
  description = <<-EOT
    ARN ваших облікових записів IAM, яким потрібен доступ kubectl до кластера.

    ЧОМУ ЦЕ ОБОВ'ЯЗКОВО: кластер створює роль HCP Terraform, і права
    адміністратора за замовчуванням отримує саме вона. Ваш власний користувач IAM
    без цього запису отримає Unauthorized на будь-яку команду kubectl.

    Узяти свій ARN: у CloudShell виконайте aws sts get-caller-identity.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.cluster_admin_arns) >= 1
    error_message = "Додайте щонайменше свій ARN, інакше kubectl не матиме доступу до кластера."
  }

  validation {
    condition     = alltrue([for a in var.cluster_admin_arns : can(regex("^arn:aws:(iam|sts)::[0-9]{12}:", a))])
    error_message = "Кожен елемент має бути ARN вигляду arn:aws:iam::123456789012:user/ім'я."
  }
}
