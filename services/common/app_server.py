from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import json
import os
import time


def make_handler(service_name, request_handler=None):
    state = {
        "requests_total": 0,
        "health_checks_total": 0,
        "ready_checks_total": 0,
        "business_requests_total": 0,
    }

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

        def do_GET(self):
            state["requests_total"] += 1
            parsed = urlparse(self.path)
            path = parsed.path

            if path == "/health":
                state["health_checks_total"] += 1
                return self._send(200, "ok", "text/plain")

            if path == "/ready":
                state["ready_checks_total"] += 1
                return self._send(200, "ready", "text/plain")

            if path == "/metrics":
                metrics = [
                    f'# HELP service_requests_total Total number of HTTP requests for {service_name}',
                    f'# TYPE service_requests_total counter',
                    f'service_requests_total{{service="{service_name}"}} {state["requests_total"]}',
                    f'health_checks_total{{service="{service_name}"}} {state["health_checks_total"]}',
                    f'ready_checks_total{{service="{service_name}"}} {state["ready_checks_total"]}',
                    f'business_requests_total{{service="{service_name}"}} {state["business_requests_total"]}',
                ]
                return self._send(200, "\n".join(metrics) + "\n", "text/plain; version=0.0.4")

            result = {"service": service_name, "message": "service is running", "path": path}
            if request_handler:
                handled = request_handler("GET", parsed, None, state)
                if handled is not None:
                    state["business_requests_total"] += 1
                    return self._json(200, handled)
            return self._json(200, result)

        def do_POST(self):
            state["requests_total"] += 1
            parsed = urlparse(self.path)
            payload = self._read_json()
            if request_handler:
                handled = request_handler("POST", parsed, payload, state)
                if handled is not None:
                    state["business_requests_total"] += 1
                    return self._json(200, handled)
            return self._json(404, {"error": "not found", "service": service_name})

        def do_OPTIONS(self):
            return self._send(204, "", "text/plain")

        def log_message(self, format, *args):
            return

    return Handler


def serve(service_name, port, request_handler=None):
    # Allow the PORT env var to override the default so multiple instances
    # can run side-by-side during local testing (e.g. test/e2e_smoke.py).
    port = int(os.environ.get("PORT", port))
    handler = make_handler(service_name, request_handler=request_handler)
    server = ThreadingHTTPServer(("0.0.0.0", port), handler)
    print(f"{service_name} listening on :{port}")
    server.serve_forever()
