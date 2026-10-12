#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Заняття 15. Запитати модель в Amazon Bedrock прямо з CloudShell.
#
#   ./ask.sh "питання"                       лише питання
#   ./ask.sh "питання" samples/pending-pod.txt   питання + дані з файлу
#   kubectl describe pod x | ./ask.sh "чому под не стартує?"
#
# Модель за замовчуванням — Amazon Nova Micro: найдешевша текстова модель
# Amazon. У Франкфурті вона доступна лише через профіль eu.… — AWS сам
# вибирає регіон ЄС, де виконати запит. Звичайний ID без eu. тут не спрацює.
#
# Що можна змінити змінними середовища:
#   MODEL=...          інша модель або профіль
#   SYSTEM_PROMPT=...  інструкція для моделі (див. завдання із зірочкою)
# ---------------------------------------------------------------------------
set -euo pipefail

MODEL="${MODEL:-eu.amazon.nova-micro-v1:0}"
REGION="${AWS_REGION:-eu-central-1}"
SYSTEM_PROMPT="${SYSTEM_PROMPT:-Ти помічник DevOps-інженера. Відповідай українською, коротко, по пунктах. Якщо даних не вистачає для висновку, так і скажи і не вигадуй.}"

QUESTION="${1:?Використання: ./ask.sh \"питання\" [файл з даними]}"

# Дані: з файлу, з конвеєра (|) або жодних.
if [ $# -ge 2 ]; then
  DATA=$(cat "$2")
elif [ ! -t 0 ]; then
  DATA=$(cat)
else
  DATA=""
fi

# Кожен рядок — це токени, а токени — це гроші. Беремо не більше 200 рядків.
DATA=$(printf '%s\n' "$DATA" | head -n 200)

# Дані загортаємо в <data>…</data>, щоб модель бачила, де питання, а де дані.
# jq збирає JSON сам: лапки й переноси рядків у даних його не зламають.
MESSAGES=$(jq -n --arg q "$QUESTION" --arg d "$DATA" '
  [{role: "user", content: [{text:
    (if ($d | test("^\\s*$")) then $q
     else $q + "\n\nДані:\n<data>\n" + $d + "\n</data>" end)
  }]}]')
SYSTEM=$(jq -n --arg s "$SYSTEM_PROMPT" '[{text: $s}]')

RESPONSE=$(aws bedrock-runtime converse \
  --region "$REGION" \
  --model-id "$MODEL" \
  --system "$SYSTEM" \
  --messages "$MESSAGES" \
  --inference-config maxTokens=600,temperature=0.2 \
  --output json)

echo "$RESPONSE" | jq -r '.output.message.content[0].text'

# Скільки коштував запит — у токенах. Ціна — на сторінці Amazon Bedrock Pricing.
echo "$RESPONSE" | jq -r '"\n--- токенів: \(.usage.inputTokens) на вхід, \(.usage.outputTokens) на вихід"' >&2
