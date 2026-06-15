from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import json
import os
import sys
import threading
import time


def make_handler(service_name, request_handler=None):
    start_time = time.time()

    state = {
        "requests_total": 0,
        "health_checks_total": 0,
        "ready_checks_total": 0,
        "business_requests_total": 0,
        "errors_total": 0,
        "in_flight": 0,
        # Histogram buckets for request latency (seconds)
        "latency_buckets": {0.005: 0, 0.01: 0, 0.025: 0, 0.05: 0, 0.1: 0, 0.25: 0, 0.5: 0, 1.0: 0, 2.5: 0, 5.0: 0, 10.0: 0},
        "latency_sum": 0.0,
        "latency_count": 0,
        # Per-path counters
        "path_hits": {},
    }
    lock = threading.Lock()

    def _record_latency(duration):
        with lock:
            state["latency_sum"] += duration
            state["latency_count"] += 1
            for boundary in state["latency_buckets"]:
                if duration <= boundary:
                    state["latency_buckets"][boundary] += 1

    def _log(level, msg, **kwargs):
        entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                 "level": level, "service": service_name, "msg": msg}
        entry.update(kwargs)
        print(json.dumps(entry), flush=True)

    class Handler(BaseHTTPRequestHandler):
        def _send(self, status_code, body, content_type="application/json"):
            self.send_response(status_code)
            self.send_header("Content-Type", content_type)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
            self.end_headers()
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.wfile.write(body)

        def _json(self, status_code, payload):
            self._send(status_code, json.dumps(payload, indent=2), "application/json")

        def _read_json(self):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8") if length else "{}"
            return json.loads(raw)

        def _metrics_text(self):
            uptime = time.time() - start_time
            svc = service_name
            lines = [
                f'# HELP service_requests_total Total HTTP requests',
                f'# TYPE service_requests_total counter',
                f'service_requests_total{{service="{svc}"}} {state["requests_total"]}',
                f'',
                f'# HELP service_errors_total Total handler errors',
                f'# TYPE service_errors_total counter',
                f'service_errors_total{{service="{svc}"}} {state["errors_total"]}',
                f'',
                f'# HELP service_in_flight_requests Current requests being served',
                f'# TYPE service_in_flight_requests gauge',
                f'service_in_flight_requests{{service="{svc}"}} {state["in_flight"]}',
                f'',
                f'# HELP service_uptime_seconds Time since service started',
                f'# TYPE service_uptime_seconds gauge',
                f'service_uptime_seconds{{service="{svc}"}} {uptime:.2f}',
                f'',
                f'# HELP health_checks_total Liveness probe hits',
                f'# TYPE health_checks_total counter',
                f'health_checks_total{{service="{svc}"}} {state["health_checks_total"]}',
                f'',
                f'# HELP ready_checks_total Readiness probe hits',
                f'# TYPE ready_checks_total counter',
                f'ready_checks_total{{service="{svc}"}} {state["ready_checks_total"]}',
                f'',
                f'# HELP business_requests_total Requests handled by business logic',
                f'# TYPE business_requests_total counter',
                f'business_requests_total{{service="{svc}"}} {state["business_requests_total"]}',
                f'',
                f'# HELP service_request_duration_seconds Request latency histogram',
                f'# TYPE service_request_duration_seconds histogram',
            ]
            cumulative = 0
            for boundary in sorted(state["latency_buckets"].keys()):
                cumulative += state["latency_buckets"][boundary]
                lines.append(f'service_request_duration_seconds_bucket{{service="{svc}",le="{boundary}"}} {cumulative}')
            lines.append(f'service_request_duration_seconds_bucket{{service="{svc}",le="+Inf"}} {state["latency_count"]}')
            lines.append(f'service_request_duration_seconds_sum{{service="{svc}"}} {state["latency_sum"]:.6f}')
            lines.append(f'service_request_duration_seconds_count{{service="{svc}"}} {state["latency_count"]}')
            lines.append('')

            # Per-path hit counter
            lines.append(f'# HELP service_path_requests_total Requests per path')
            lines.append(f'# TYPE service_path_requests_total counter')
            for path, count in state["path_hits"].items():
                lines.append(f'service_path_requests_total{{service="{svc}",path="{path}"}} {count}')
            lines.append('')
            return "\n".join(lines) + "\n"

        def do_GET(self):
            t0 = time.monotonic()
            state["requests_total"] += 1
            state["in_flight"] += 1
            parsed = urlparse(self.path)
            path = parsed.path

            try:
                if path == "/health":
                    state["health_checks_total"] += 1
                    return self._send(200, "ok", "text/plain")

                if path == "/ready":
                    state["ready_checks_total"] += 1
                    return self._send(200, "ready", "text/plain")

                if path == "/metrics":
                    return self._send(200, self._metrics_text(), "text/plain; version=0.0.4; charset=utf-8")

                state["path_hits"][path] = state["path_hits"].get(path, 0) + 1

                if request_handler:
                    handled = request_handler("GET", parsed, None, state)
                    if handled is not None:
                        state["business_requests_total"] += 1
                        return self._json(200, handled)
                return self._json(200, {"service": service_name, "message": "service is running", "path": path})
            except Exception as exc:
                state["errors_total"] += 1
                _log("error", "handler exception", error=str(exc), path=path)
                return self._json(500, {"error": str(exc), "service": service_name})
            finally:
                state["in_flight"] -= 1
                _record_latency(time.monotonic() - t0)

        def do_POST(self):
            t0 = time.monotonic()
            state["requests_total"] += 1
            state["in_flight"] += 1
            parsed = urlparse(self.path)
            path = parsed.path
            state["path_hits"][path] = state["path_hits"].get(path, 0) + 1

            try:
                payload = self._read_json()
                if request_handler:
                    handled = request_handler("POST", parsed, payload, state)
                    if handled is not None:
                        state["business_requests_total"] += 1
                        _log("info", "business_request", path=path, method="POST")
                        return self._json(200, handled)
                return self._json(404, {"error": "not found", "service": service_name})
            except Exception as exc:
                state["errors_total"] += 1
                _log("error", "handler exception", error=str(exc), path=path)
                return self._json(500, {"error": str(exc), "service": service_name})
            finally:
                state["in_flight"] -= 1
                _record_latency(time.monotonic() - t0)

        def do_OPTIONS(self):
            return self._send(204, "", "text/plain")

        def log_message(self, format, *args):
            return

    return Handler


def serve(service_name, port, request_handler=None):
    port = int(os.environ.get("PORT", port))
    handler = make_handler(service_name, request_handler=request_handler)
    server = ThreadingHTTPServer(("0.0.0.0", port), handler)
    print(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      "level": "info", "service": service_name,
                      "msg": "server_started", "port": port}), flush=True)
    server.serve_forever()
