# ---------------------------------------------------------------------------
# Заняття 14. Маленький shop, який сам віддає свої метрики.
#
# Лише стандартна бібліотека Python — нічого не встановлюємо.
# Справжні застосунки роблять те саме бібліотекою prometheus_client
# (або її аналогом для своєї мови); формат на виході однаковий.
#
#   /            200
#   /api/items   200, 10–120 мс
#   /api/pay     200, 50–300 мс; частина запитів завершується 503
#   /healthz     200
#   /metrics     метрики у текстовому форматі Prometheus
#   /chaos       зламати або полагодити сервіс:
#                  /chaos?error_rate=0.5   половина /api/pay — помилки
#                  /chaos?delay_ms=800     усі запити повільніші на 800 мс
#                  /chaos?error_rate=0.02&delay_ms=0   повернути як було
# ---------------------------------------------------------------------------
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# Межі кошиків гістограми, у секундах.
BUCKETS = [0.05, 0.1, 0.25, 0.5, 1.0, 2.5]

# Відомі шляхи. Усе інше рахуємо як "other": якщо класти в мітку будь-який
# шлях, кожен випадковий URL створить новий часовий ряд (висока кардинальність).
KNOWN_PATHS = {"/", "/api/items", "/api/pay", "/healthz"}

lock = threading.Lock()
requests_total = {}       # (method, path, status) -> лічильник
duration_buckets = {}     # (path, le) -> скільки спостережень <= le
duration_sum = {}         # path -> сума тривалостей
duration_count = {}       # path -> кількість спостережень
inflight = 0
chaos = {"error_rate": 0.02, "delay_ms": 0}


def observe(method, path, status, seconds):
    with lock:
        key = (method, path, str(status))
        requests_total[key] = requests_total.get(key, 0) + 1
        for le in BUCKETS + ["+Inf"]:
            if le == "+Inf" or seconds <= le:
                duration_buckets[(path, le)] = duration_buckets.get((path, le), 0) + 1
        duration_sum[path] = duration_sum.get(path, 0.0) + seconds
        duration_count[path] = duration_count.get(path, 0) + 1


def render_metrics():
    out = []
    with lock:
        out.append("# HELP shop_http_requests_total Кількість оброблених HTTP-запитів.")
        out.append("# TYPE shop_http_requests_total counter")
        for (method, path, status), value in sorted(requests_total.items()):
            out.append(f'shop_http_requests_total{{method="{method}",path="{path}",status="{status}"}} {value}')

        out.append("# HELP shop_http_request_duration_seconds Тривалість обробки запиту.")
        out.append("# TYPE shop_http_request_duration_seconds histogram")
        for path in sorted(duration_count):
            for le in BUCKETS + ["+Inf"]:
                le_text = le if le == "+Inf" else repr(float(le))
                out.append(f'shop_http_request_duration_seconds_bucket{{path="{path}",le="{le_text}"}} {duration_buckets.get((path, le), 0)}')
            out.append(f'shop_http_request_duration_seconds_sum{{path="{path}"}} {duration_sum[path]:.6f}')
            out.append(f'shop_http_request_duration_seconds_count{{path="{path}"}} {duration_count[path]}')

        out.append("# HELP shop_inflight_requests Запити, які обробляються просто зараз.")
        out.append("# TYPE shop_inflight_requests gauge")
        out.append(f"shop_inflight_requests {inflight}")

        out.append("# HELP shop_chaos_error_rate Поточна частка навмисних помилок /api/pay.")
        out.append("# TYPE shop_chaos_error_rate gauge")
        out.append(f"shop_chaos_error_rate {chaos['error_rate']}")

        out.append("# HELP shop_chaos_delay_seconds Поточна навмисна затримка кожного запиту.")
        out.append("# TYPE shop_chaos_delay_seconds gauge")
        out.append(f"shop_chaos_delay_seconds {chaos['delay_ms'] / 1000}")
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body, content_type="text/plain; charset=utf-8"):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        global inflight
        url = urlparse(self.path)

        # Службові адреси не рахуємо в метриках запитів.
        if url.path == "/metrics":
            return self.reply(200, render_metrics(), "text/plain; version=0.0.4; charset=utf-8")
        if url.path == "/chaos":
            query = parse_qs(url.query)
            with lock:
                if "error_rate" in query:
                    chaos["error_rate"] = min(max(float(query["error_rate"][0]), 0.0), 1.0)
                if "delay_ms" in query:
                    chaos["delay_ms"] = max(int(query["delay_ms"][0]), 0)
                state = dict(chaos)
            return self.reply(200, f"error_rate={state['error_rate']} delay_ms={state['delay_ms']}\n")

        started = time.monotonic()
        with lock:
            inflight += 1
            delay = chaos["delay_ms"] / 1000
            error_rate = chaos["error_rate"]
        try:
            path = url.path if url.path in KNOWN_PATHS else "other"
            if path == "/":
                status, body = 200, "shop: metrics stand. try /api/items, /api/pay, /metrics\n"
            elif path == "/healthz":
                status, body = 200, "ok\n"
            elif path == "/api/items":
                time.sleep(random.uniform(0.01, 0.12))
                status, body = 200, '[{"id":1,"name":"coffee"},{"id":2,"name":"tea"}]\n'
            elif path == "/api/pay":
                time.sleep(random.uniform(0.05, 0.3))
                if random.random() < error_rate:
                    status, body = 503, '{"error":"payment backend unavailable"}\n'
                else:
                    status, body = 200, '{"paid":true}\n'
            else:
                status, body = 404, "not found\n"
            time.sleep(delay)
            self.reply(status, body)
        finally:
            observe("GET", path, status, time.monotonic() - started)
            with lock:
                inflight -= 1

    # Не засмічувати stdout рядком на кожен запит: сьогодні нас цікавлять метрики.
    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print("shop listening on :8000", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
