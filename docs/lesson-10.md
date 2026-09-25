# Заняття 10. Трафік і секрети

Сьогодні до застосунку вперше можна дістатися з інтернету без `port-forward`,
а секрети приходять у кластер з AWS, а не з git.

Файли Terraform заняття лежать у `lessons/10-traffic-secrets/` і, як на
занятті 9, копіюються в `cluster/`. Воркспейс той самий, один на весь курс.

| Компонент | Хто ставить | Що робить |
|---|---|---|
| Ролі IAM і асоціації Pod Identity | Terraform, `platform-iam.tf` | Дають подам компонентів доступ до AWS без ключів |
| AWS Load Balancer Controller | Flux, `infrastructure/` | Створює NLB для `Service` типу `LoadBalancer` |
| External Secrets Operator | Flux, `infrastructure/` | Робить із параметрів Parameter Store звичайні `Secret` |
| Синхронізація `infra-sync` | Terraform, `flux-infrastructure.tf` | Каже Flux застосовувати теку `infrastructure/` |

---

## 0. Оновити свій форк

На GitHub відкрийте свій форк і натисніть **Sync fork → Update branch**.

Якщо GitHub пише про конфлікт і пропонує **Discard commits**, погоджуйтесь:
ваші зміни з минулого заняття були навчальні, а нова версія файлів їх перекриває.

Потім у своїй локальній копії:

```bash
git pull
```

Перевірка: у репозиторії з'явились теки `lessons/10-traffic-secrets/`,
`infrastructure/` і `docs/`.

---

## 1. Підняти вузол

У **CloudShell**:

```bash
NG=$(aws eks list-nodegroups --cluster-name <prefix>-eks \
       --query 'nodegroups[0]' --output text)
aws eks update-nodegroup-config --cluster-name <prefix>-eks \
       --nodegroup-name $NG --scaling-config desiredSize=1
```

> **Виправлення до занять 8–9.** Модуль EKS свідомо ігнорує зміни
> `desired_size` (він стоїть у `ignore_changes`), щоб Terraform не відкочував
> рішення автомасштабувальника. Тому `terraform apply -var node_desired_size=…`
> кількість вузлів насправді не змінює. Піднімаємо й опускаємо вузли командою вище.

Вузол піднімається дві-три хвилини. Поки йде — наступний крок.

---

## 2. Параметри в Parameter Store

У **CloudShell**:

```bash
aws ssm put-parameter --name /shop/banner \
  --type String --value "hello from Parameter Store"

aws ssm put-parameter --name /shop/db-password \
  --type SecureString --value "$(openssl rand -base64 18)"
```

Значення секрету **не потрапляє ні в git, ні в стан Terraform**. Воно існує
лише в AWS, і в кластер його приносить оператор.

Перевірка: `aws ssm get-parameters-by-path --path /shop --query 'Parameters[].Name'`
показує обидва імені.

---

## 3. Файли заняття в cluster/ і один apply

Дочекайтесь, поки вузол у стані `Ready` (`kubectl get nodes`), тоді:

```bash
cp -r lessons/10-traffic-secrets/. cluster/     # -r: разом із текою policies/
cd cluster
terraform apply
```

| Файл | Що додає |
|---|---|
| `platform-iam.tf` | дві ролі, політику LBC і її прив'язку, вбудовану політику ESO, дві асоціації Pod Identity |
| `policies/` | офіційну політику контролера v3.5.0 — через неї копіюємо з `-r` |
| `flux-infrastructure.tf` | синхронізацію `infra-sync` для теки `infrastructure/` |
| `flux.tf` | **замінює** файл із заняття 9: у `shop-sync` додалось `dependsOn: infra-sync` |

План: **8 to add, 1 to change**. Інше число — найчастіше скопійовано без `-r`
або не зроблено `git pull`.

Перевірка асоціацій:

```bash
aws eks list-pod-identity-associations --cluster-name <prefix>-eks \
  --query 'associations[].serviceAccount' --output text
# ebs-csi-controller-sa   aws-load-balancer-controller   external-secrets
```

Спостерігайте, як Flux ставить компоненти:

```bash
kubectl get kustomizations -n flux-system       # infra-sync -> True, потім shop-sync
kubectl get helmreleases -n flux-system         # обидва READY True
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get pods -n external-secrets            # три поди
```

---

## 4. Практика 1. Вхід з інтернету

1. У своєму форку в `apps/shop/kustomization.yaml` розкоментуйте рядок
   `- web-public.yaml`. Закомітьте й запуште.
2. Дочекайтесь, поки Flux застосує зміну, і подивіться на сервіс:

   ```bash
   kubectl get svc web-public -n shop -w
   ```

   У колонці `EXTERNAL-IP` з'явиться ім'я вигляду
   `k8s-shop-....elb.eu-central-1.amazonaws.com`.
3. Зачекайте дві-три хвилини: балансувальник створюється, цілі проходять
   перевірку здоров'я, запис DNS розходиться.

   ```bash
   curl http://<ім'я>/
   curl http://<ім'я>/api/
   ```

4. У консолі **EC2 → Load Balancers** знайдіть свій NLB, відкрийте його
   target group. Адреси цілей збігаються з `kubectl get pods -n shop -o wide`
   — це і є `target-type: ip`.

---

## 5. Практика 2. Секрети з AWS

1. У `apps/shop/kustomization.yaml` розкоментуйте **обидва** рядки:
   `- secret-store.yaml` і `- external-secret.yaml`. Закомітьте й запуште.
2. Перевірте:

   ```bash
   kubectl get secretstore,externalsecret -n shop
   # SecretStore  STATUS Valid       ExternalSecret  STATUS SecretSynced

   kubectl get secret shop-config -n shop -o jsonpath='{.data.BANNER}' | base64 -d
   curl http://<ім'я>/banner
   ```

3. **Файл оновлюється сам.** Змініть банер в AWS:

   ```bash
   aws ssm put-parameter --name /shop/banner --value "banner v2" --overwrite
   ```

   Через хвилину оператор оновить `Secret`, ще за хвилину-дві kubelet оновить
   змонтований файл. Повторюйте `curl .../banner` — з'явиться `banner v2`,
   хоча жоден под не перезапускався.

4. **Змінна — ні.**

   ```bash
   kubectl exec -n shop deploy/api -- printenv DB_PASSWORD
   ```

   Порожньо: поди `api` стартували раніше, ніж з'явився `Secret`, а змінні
   середовища читаються лише на старті. Перезапустіть:

   ```bash
   kubectl rollout restart deploy/api -n shop
   kubectl rollout status deploy/api -n shop
   kubectl exec -n shop deploy/api -- printenv DB_PASSWORD
   ```

---

## 6. Прибирання — у цьому порядку

1. У `apps/shop/kustomization.yaml` **закоментуйте** `- web-public.yaml`,
   закомітьте й запуште.
2. Дочекайтесь, поки сервіс зникне, а в **EC2 → Load Balancers** зникне NLB:

   ```bash
   kubectl get svc -n shop       # web-public більше немає
   ```

3. Лише тепер опускайте вузли — тією самою командою, що на початку:

   ```bash
   NG=$(aws eks list-nodegroups --cluster-name <prefix>-eks \
          --query 'nodegroups[0]' --output text)     # якщо CloudShell перезапускався
   aws eks update-nodegroup-config --cluster-name <prefix>-eks \
          --nodegroup-name $NG --scaling-config desiredSize=0
   ```

**Чому саме такий порядок.** NLB тарифікується погодинно незалежно від вузлів:
близько $0.04 на годину разом із публічними адресами в трьох зонах, тобто
приблизно $30 на місяць. А прибрати його може лише контролер — той, що
працює на вузлі. Опустили вузли першими — контролера немає, і балансувальник
лишається висіти.

Параметри в Parameter Store можна не видаляти: звичайні параметри безкоштовні.

---

## Пастки

**`EXTERNAL-IP` висить у `<pending>`.** Подивіться журнал контролера:
`kubectl logs -n kube-system deploy/aws-load-balancer-controller`.
`AccessDenied` або «no credentials» означає, що под стартував раніше, ніж
з'явилась асоціація Pod Identity. Лікується перезапуском:
`kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system`.

**Ім'я балансувальника є, але `curl` не відповідає.** Нормально перші
дві-три хвилини. Якщо довше — у target group цілі в стані `unhealthy`:
перевірте, що поди `web` у `Ready`.

**`shop-sync` не оновлюється, у статусі `dependency ... is not ready`.**
Застосунок чекає інфраструктуру. Дивіться, що з нею:
`kubectl describe kustomization infra-sync -n flux-system` і
`kubectl get helmreleases -n flux-system`.

**`ExternalSecret` у стані `SecretSyncedError`.** `kubectl describe externalsecret shop-config -n shop`.
Найчастіше — помилка в імені параметра або параметр поза шляхом `/shop/`:
роль оператора дозволяє читати лише його.

**Хочу змінити `loadBalancerClass`.** Не можна: поле незмінне після створення
сервісу. Лише видалити сервіс і створити знову.

**Видаляти кластер, коли NLB ще живий, не можна.** Балансувальник і його
security groups створив контролер, а не Terraform. `terraform destroy`
упреться у VPC, від якої не відв'язані ці ресурси. Спочатку прибрати
сервіс, потім — усе інше.

---

## Ресурси вузла після заняття

Орієнтовні числа, перевірте реальні через
`kubectl describe node <ім'я> | grep -A8 "Allocated resources"`.

| Що додалось | Подів | CPU requests | Пам'ять requests |
|---|---|---|---|
| AWS Load Balancer Controller | 1 | 50m | 128Mi |
| External Secrets Operator | 3 | 30m | 128Mi |
| **Разом нового** | **4** | **80m** | **256Mi** |

На одному `c7i-flex.large` це лишає достатній запас для бази даних на занятті 11.
