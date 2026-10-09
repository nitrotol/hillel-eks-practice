# Заняття 14. Моніторинг: метрики й алерти

На занятті — теорія. Усе, що нижче, — **домашнє завдання, і воно необов'язкове**.
Завдання прості; перше не залежить від решти.

| Завдання | Що потрібно | Час |
|---|---|---|
| 1. Метрики, які кластер уже віддає | кластер (вузол — лише для другої половини) | 10 хв |
| 2. Локальний стенд: запити до метрик | лише Docker, без AWS | 15 хв |
| 3. Зламати сервіс і побачити алерт | стенд із завдання 2 | 15 хв |
| 4. Із зірочкою: власне правило алерту | стенд із завдання 2 | 10 хв |

---

## Завдання 1. Метрики, які кластер уже віддає

Кожен компонент Kubernetes віддає метрики у форматі Prometheus — їх можна
прочитати звичайним `kubectl`. Сервер API працює на боці AWS, тому для першої
половини вузол не потрібен.

```bash
kubectl get --raw /metrics | head -20
kubectl get --raw /metrics | grep '^# TYPE apiserver_request_total'
kubectl get --raw /metrics | grep '^apiserver_request_total' | grep 'resource="pods"' | head
```

Подивіться на рядки `apiserver_request_total{…} 123`: це **лічильник** із
мітками `verb`, `resource`, `code`. Кожна унікальна комбінація міток — окремий
часовий ряд.

Скільки всього рядків зі значеннями віддає сервер API:

```bash
kubectl get --raw /metrics | grep -vc '^#'
```

У кластерах EKS від версії 1.28 є ще й метрики планувальника — компонента,
до якого інакше не дістатися:

```bash
kubectl get --raw /apis/metrics.eks.amazonaws.com/v1/ksh/container/metrics | head -20
```

**Друга половина — з піднятим вузлом.** kubelet на кожному вузлі віддає
метрики контейнерів (вбудований cAdvisor):

```bash
NG=$(aws eks list-nodegroups --cluster-name <prefix>-eks \
       --query 'nodegroups[0]' --output text)
aws eks update-nodegroup-config --cluster-name <prefix>-eks \
       --nodegroup-name $NG --scaling-config desiredSize=1

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl get --raw /api/v1/nodes/$NODE/proxy/metrics/cadvisor \
  | grep '^container_memory_working_set_bytes' | grep 'namespace="shop"'
```

Це пам'ять, яку зараз займає кожен контейнер shop, у байтах — **датчик**
(gauge): значення може і рости, і падати.

**Готово, коли:** ви знайшли `apiserver_request_total` і можете показати в
одному рядку назву метрики, мітки й значення.

---

## Завдання 2. Локальний стенд: запити до метрик

```
shop (/metrics)  <--збирає кожні 10 с--  victoriametrics  <--запити--  vmalert
    ^                                          |
 loadgen                          http://localhost:8428/vmui
```

```bash
cd lessons/14-metrics
docker compose up -d
docker compose ps                  # чотири контейнери у стані running
curl -s localhost:8000/metrics | head -20
```

Останнє — сирі метрики застосунку: так їх бачить збирач. Як вони
рахуються — у `shop/app.py`, що збирати — у `victoriametrics/scrape.yml`.

Відкрийте **http://localhost:8428/vmui**. Вставляйте запити по черзі й
натискайте **Execute**; вкладка **Graph** показує графік, **Table** — числа.
Зачекайте хвилину після запуску, щоб накопичились дані.

```
up
```
1 — ціль відповідає, 0 — ні. Три цілі: shop, victoriametrics, vmalert

```
shop_http_requests_total
```
сирі лічильники: лише ростуть, тому самі по собі мало що кажуть

```
sum by (status) (rate(shop_http_requests_total[1m]))
```
запитів за секунду з кожним статусом

```
sum(rate(shop_http_requests_total{status=~"5.."}[1m])) / sum(rate(shop_http_requests_total[1m]))
```
частка помилок сервера: зазвичай близько 0.02, тобто 2%

```
histogram_quantile(0.95, sum by (le) (rate(shop_http_request_duration_seconds_bucket[1m])))
```
95-й перцентиль часу відповіді: 95% запитів швидші за це число секунд

**Готово, коли:** ви можете сказати, скільки запитів за секунду обробляє shop,
яка частка помилок і який 95-й перцентиль часу відповіді.

---

## Завдання 3. Зламати сервіс і побачити алерт

Правила алертів — у `vmalert/alerts.yml`. Подивіться на них в інтерфейсі:
у меню vmui відкрийте **Rules** (у вузькому вікні меню ховається під кнопкою ☰)
і клацніть групу `shop`.
Обидва правила зараз у стані `inactive`. Клацніть правило — побачите його
запит, `for`, мітки й активні алерти.

1. Зламайте платіжний сервіс — половина `/api/pay` почне відповідати 503:

   ```bash
   curl "localhost:8000/chaos?error_rate=0.5"
   ```

2. Спостерігайте за правилом `ShopHighErrorRate` на сторінці **Rules**
   (кнопка **Refresh**) і графіком частки помилок із завдання 2:

   - приблизно за хвилину алерт стане **pending** — умова виконується, але ще
     не довше за `for: 1m`;
   - ще приблизно за хвилину — **firing**.

3. Полагодьте:

   ```bash
   curl "localhost:8000/chaos?error_rate=0.02"
   ```

   За дві-три хвилини алерт зникне: вікно `[1m]` має «забути» помилки.

4. Тепер інший алерт — сервіс зовсім не відповідає:

   ```bash
   docker compose stop shop     # приблизно за хвилину-півтори ShopDown стане firing
   docker compose start shop    # і зникне за хвилину після запуску
   ```

**Готово, коли:** ви бачили обидва алерти в стані firing і бачили, як вони
зникають після виправлення.

---

## Завдання 4. Із зірочкою: власне правило алерту

У `vmalert/alerts.yml` унизу є закоментоване правило `ShopSlowRequests`:
95% запитів мають укладатися в пів секунди.

1. Приберіть на початку п'яти рядків символи `# ` (решітку й один пробіл).
   Відступи мають збігтися з правилами вище.
2. Перезапустіть vmalert: `docker compose restart vmalert`.
3. Додайте затримку: `curl "localhost:8000/chaos?delay_ms=800"`.
4. Приблизно за дві хвилини `ShopSlowRequests` стане firing. Поверніть:
   `curl "localhost:8000/chaos?delay_ms=0"`.

**Готово, коли:** ваше правило спрацювало від затримки й зникло після її
прибирання.

---

## Прибирання

```bash
docker compose down -v
```

Якщо піднімали вузол — опустіть:

```bash
aws eks update-nodegroup-config --cluster-name <prefix>-eks \
       --nodegroup-name $NG --scaling-config desiredSize=0
```

---

## Здача

Коментар у LMS до завдання — що з переліченого ви зробили:

- завдання 1: один рядок `apiserver_request_total` із вашого кластера;
- завдання 2: значення частки помилок і 95-го перцентиля;
- завдання 3–4: знімок екрана з алертом у стані firing.

---

## Пастки

**`kubectl get --raw /metrics` каже `Forbidden`.** Ваш користувач не адміністратор
кластера. Перевірте `cluster_admin_arns` у `terraform.tfvars`.

**`docker compose up` каже `port is already allocated`.** Порт 8000 або 8428
зайнятий. Змініть ліву частину в `compose.yaml`, наприклад `"8001:8000"`,
і використовуйте нову адресу.

**Запит повертає порожньо.** Перевірте проміжок часу вгорі праворуч і зачекайте
хвилину: функції `rate()` потрібні щонайменше дві точки у вікні.

**У меню vmui немає Rules або сторінка порожня.** Не стартував vmalert:
`docker compose logs vmalert --tail=20`. Найчастіша причина — помилка у
відступах `alerts.yml` після правки.

**Алерт довго не спрацьовує.** Так і має бути: дані збираються раз на 10 секунд,
правила перевіряються раз на 15, vmalert свідомо відстає на пів хвилини, щоб
дані встигли надійти, а `for:` ще чекає. Від поломки до firing — дві-три хвилини.

---

## Якщо цікаво піти далі

Той самий набір у кластері — це чарт `kube-prometheus-stack` (Prometheus,
Alertmanager, Grafana, node-exporter, kube-state-metrics) або
`victoria-metrics-k8s-stack`. Обидва важкі для нашого єдиного вузла: розрахунок
ресурсів — у `README.md`.
