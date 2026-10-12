# Заняття 15. Запитати модель з терміналу

Нічого з цієї теки не копіюється в `cluster/`. Скрипт працює в **CloudShell**
і звертається до Amazon Bedrock. Кластер для цього не потрібен.

```bash
git clone https://github.com/ваш-логін/hillel-eks-practice
cd hillel-eks-practice/lessons/15-ai
./ask.sh "Що таке Pod Identity в EKS? Два речення."
./ask.sh "Чому под не стартує і що зробити?" samples/pending-pod.txt
```

| Файл | Що в ньому |
|---|---|
| `ask.sh` | питання (і дані) → модель у Bedrock → відповідь і кількість токенів |
| `samples/pending-pod.txt` | `kubectl describe pod` для пода, що висить у `Pending` |
| `samples/destroy-error.txt` | помилка `terraform destroy`, яку легко отримати при прибиранні |
| `samples/access-injected.log` | журнал nginx (формат заняття 13) з «сюрпризом» для завдання із зірочкою |

Модель за замовчуванням — Amazon Nova Micro через профіль
`eu.amazon.nova-micro-v1:0`. Один запит із файлом на кілька сотень рядків —
це соті частки цента з ваших кредитів.

Завдання — у `docs/lesson-15.md`.
