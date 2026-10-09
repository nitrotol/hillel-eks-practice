# Заняття 14. Локальний стенд для метрик і алертів

```
shop (/metrics)  <--збирає кожні 10 с--  victoriametrics  <--запити--  vmalert
```

Нічого з цієї теки не копіюється в `cluster/`: стенд працює на вашому
комп'ютері в Docker Compose і не потребує AWS.

```bash
docker compose up -d
# застосунок і його метрики: http://localhost:8000/metrics
# запити, графіки, алерти:   http://localhost:8428/vmui
docker compose down -v
```

| Файл | Що в ньому |
|---|---|
| `compose.yaml` | чотири сервіси стенда |
| `shop/app.py` | застосунок, який сам рахує свої метрики; `/chaos` — щоб його зламати |
| `victoriametrics/scrape.yml` | що і як часто збирати (формат `prometheus.yml`) |
| `vmalert/alerts.yml` | правила алертів (формат правил Prometheus) |

Завдання й запити — у `docs/lesson-14.md`.
