import json
import os
import urllib.error
import urllib.request
from common.app_server import serve


TRINO_URL = os.environ.get("TRINO_URL", "http://trino.analytics.svc.cluster.local:8080")
TRINO_USER = os.environ.get("TRINO_USER", "platform")
TRINO_CATALOG = os.environ.get("TRINO_CATALOG", "postgresql")
TRINO_SCHEMA = os.environ.get("TRINO_SCHEMA", "catalog")


def _json_request(url, method="GET", body=None, headers=None, timeout=20):
    payload = body.encode("utf-8") if isinstance(body, str) else body
    request_headers = headers or {}
    req = urllib.request.Request(url=url, data=payload, headers=request_headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        raw = response.read().decode("utf-8")
        if not raw:
            return {}
        return json.loads(raw)


def choose_cluster(query):
    normalized = query.lower()
    if any(keyword in normalized for keyword in ["join", "group by", "count(", "sum(", "scan", "history"]):
        return "analytics"
    if len(query) > 120:
        return "analytics"
    return "interactive"


def query_trino(sql, cluster, max_rows=200):
    if not sql.strip():
        return {"error": "Query is empty."}

    # Keep this service read-oriented for frontend usage.
    allowed_prefixes = ("select", "with", "show", "describe", "explain")
    if not sql.strip().lower().startswith(allowed_prefixes):
        return {"error": "Only read queries are allowed (SELECT/WITH/SHOW/DESCRIBE/EXPLAIN)."}

    headers = {
        "X-Trino-User": TRINO_USER,
        "X-Trino-Catalog": TRINO_CATALOG,
        "X-Trino-Schema": TRINO_SCHEMA,
        "X-Trino-Source": f"query-router-{cluster}",
        "Content-Type": "text/plain; charset=utf-8",
    }

    try:
        response = _json_request(
            url=f"{TRINO_URL}/v1/statement",
            method="POST",
            body=sql,
            headers=headers,
            timeout=25,
        )
    except urllib.error.HTTPError as exc:
        return {"error": f"Trino HTTP error: {exc.code} {exc.reason}"}
    except Exception as exc:
        return {"error": f"Unable to reach Trino: {exc}"}

    columns = [c.get("name", "") for c in response.get("columns", [])]
    rows = list(response.get("data", []))
    next_uri = response.get("nextUri")

    while next_uri and len(rows) < max_rows:
        page = _json_request(
            url=next_uri,
            method="GET",
            headers={"X-Trino-User": TRINO_USER},
            timeout=25,
        )
        if page.get("columns") and not columns:
            columns = [c.get("name", "") for c in page.get("columns", [])]
        rows.extend(page.get("data", []))
        next_uri = page.get("nextUri")
        if page.get("error"):
            err = page["error"]
            return {
                "error": err.get("message", "Trino query failed"),
                "errorName": err.get("errorName", "UNKNOWN"),
            }

    return {
        "columns": columns,
        "rows": rows[:max_rows],
        "rowCount": len(rows[:max_rows]),
        "truncated": next_uri is not None,
    }


def handle(method, parsed, payload, state):
    if parsed.path == "/query" and method == "POST":
        query = payload.get("query", "")
        max_rows = int(payload.get("maxRows", 200))
        cluster = choose_cluster(query)
        result = query_trino(query, cluster, max_rows=max_rows)
        if result.get("error"):
            return {
                "status": "error",
                "cluster": cluster,
                "route": f"trino-{cluster}",
                "query": query,
                "error": result["error"],
                "errorName": result.get("errorName"),
            }
        return {
            "query": query,
            "cluster": cluster,
            "route": f"trino-{cluster}",
            "trinoEndpoint": TRINO_URL,
            "status": "ok",
            "columns": result["columns"],
            "rows": result["rows"],
            "rowCount": result["rowCount"],
            "truncated": result["truncated"],
        }
    if parsed.path == "/cluster" and method == "GET":
        return {"interactive": "trino-interactive", "analytics": "trino-analytics"}
    return None


if __name__ == "__main__":
    serve("query-router", 8080, handle)
