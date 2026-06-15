import time
import urllib.request
import urllib.error
from common.app_server import serve


def _probe(url, timeout=5):
    """HEAD then GET the URL and return (status, latency_ms, error)."""
    if not url or not url.startswith("http"):
        return "SKIP", 0, "no valid URL"
    start = time.monotonic()
    try:
        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = resp.status
    except urllib.error.HTTPError as exc:
        code = exc.code          # e.g. 405 Method Not Allowed still means the host is up
    except Exception as exc:
        return "DOWN", int((time.monotonic() - start) * 1000), str(exc)
    latency = int((time.monotonic() - start) * 1000)
    status = "UP" if code < 500 else "DOWN"
    return status, latency, None


def handle(method, parsed, payload, state):
    if parsed.path == "/validate" and method == "POST":
        url = payload.get("url", "")
        status, latency, error = _probe(url)
        result = {"url": url, "status": status, "latencyMs": latency, "checked": True}
        if error:
            result["error"] = error
        return result

    if parsed.path == "/validate/batch" and method == "POST":
        # [{"name": "...", "baseUrl": "..."}]
        items = payload.get("items", [])
        results = []
        for item in items[:10]:   # cap at 10 per request on local Mac
            url = item.get("baseUrl") or item.get("url", "")
            status, latency, error = _probe(url)
            row = {"name": item.get("name", ""), "url": url, "status": status, "latencyMs": latency}
            if error:
                row["error"] = error
            results.append(row)
        return {"validated": len(results), "items": results}

    return None


if __name__ == "__main__":
    serve("api-validator", 8080, handle)
