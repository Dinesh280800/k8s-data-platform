#!/usr/bin/env python3
"""
End-to-end smoke test for the data-platform services.

Runs every service in a subprocess, walks the full pipeline:
  discover → validate (batch) → enrich (batch) → query-route

Usage:
    cd /path/to/k8s-data-platform
    python3 test/e2e_smoke.py

Requirements: Python 3.8+, no extra packages.
Set E2E_SOURCE=apis-guru to use the APIs.guru source instead of publicapis.
Set E2E_LIMIT=5  to override how many APIs to discover.
"""

import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

# ── config ────────────────────────────────────────────────────────────────────
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICES = {
    "api-discovery": 8081,
    "api-validator": 8082,
    "api-enricher":  8083,
    "query-router":  8084,
}
SOURCE  = os.environ.get("E2E_SOURCE", "publicapis")
LIMIT   = int(os.environ.get("E2E_LIMIT", "5"))
TIMEOUT = 10   # seconds per HTTP call

COLORS = {
    "green":  "\033[92m",
    "yellow": "\033[93m",
    "red":    "\033[91m",
    "cyan":   "\033[96m",
    "reset":  "\033[0m",
}

def c(color, text):
    return f"{COLORS[color]}{text}{COLORS['reset']}"

# ── helpers ───────────────────────────────────────────────────────────────────

def call(port, path, method="GET", body=None):
    url = f"http://localhost:{port}{path}"
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(url, data=data,
                                  headers={"Content-Type": "application/json"},
                                  method=method)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read())


def wait_ready(name, port, retries=20, delay=0.5):
    for i in range(retries):
        try:
            urllib.request.urlopen(f"http://localhost:{port}/ready", timeout=2)
            return
        except Exception:
            time.sleep(delay)
    print(c("red", f"  ✗ {name} did not become ready on port {port}"))
    sys.exit(1)


def start_service(name, port):
    env = os.environ.copy()
    env["PYTHONPATH"] = REPO_ROOT + "/services"
    proc = subprocess.Popen(
        [sys.executable, f"{REPO_ROOT}/services/{name}/main.py"],
        env=env,
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    # Override port via monkey-patch is not easy; services use the default 8080.
    # We instead start each service with a PORT env var and patch app_server to honour it.
    return proc


def start_services():
    """Start each service on a dedicated port via PORT env var."""
    procs = {}
    for name, port in SERVICES.items():
        env = os.environ.copy()
        env["PYTHONPATH"] = REPO_ROOT + "/services"
        env["PORT"] = str(port)
        proc = subprocess.Popen(
            [sys.executable, f"{REPO_ROOT}/services/{name}/main.py"],
            env=env,
            cwd=REPO_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        procs[name] = proc
    return procs


def stop_services(procs):
    for name, proc in procs.items():
        proc.terminate()
        proc.wait(timeout=5)


def section(title):
    print(f"\n{c('cyan', '═══ ' + title + ' ═══')}")


def ok(msg):
    print(c("green",  f"  ✓ {msg}"))

def info(msg):
    print(f"    {msg}")

def warn(msg):
    print(c("yellow", f"  ⚠ {msg}"))

# ── pipeline steps ─────────────────────────────────────────────────────────────

def step_discover(disc_port):
    section(f"Step 1 – DISCOVER  (source={SOURCE}, limit={LIMIT})")
    resp = call(disc_port, f"/discover?source={SOURCE}&limit={LIMIT}")
    apis = resp.get("apis", [])
    ok(f"Discovered {len(apis)} APIs from '{SOURCE}'")
    for a in apis[:3]:
        info(f"{a.get('name','?'):40s}  {a.get('baseUrl','')[:60]}")
    if len(apis) > 3:
        info(f"  … and {len(apis) - 3} more")
    return apis


def step_validate(val_port, apis):
    section("Step 2 – VALIDATE  (probe each API base URL)")
    items = [{"name": a.get("name",""), "baseUrl": a.get("baseUrl",""),
              "url": a.get("baseUrl","")} for a in apis]
    resp  = call(val_port, "/validate/batch", method="POST", body={"items": items})
    validated = resp.get("items", [])
    up_count  = sum(1 for v in validated if v.get("status") == "UP")
    ok(f"Validated {len(validated)} APIs — {up_count} UP, {len(validated) - up_count} DOWN/SKIP")
    for v in validated:
        color = "green" if v.get("status") == "UP" else "yellow"
        print(c(color, f"  [{v.get('status','?'):5s}]") +
              f"  {v.get('name','?'):40s}  {v.get('latencyMs', 0)}ms")
    return validated


def step_enrich(enr_port, validated):
    section("Step 3 – ENRICH  (tag and classify)")
    items = []
    for v in validated:
        items.append({
            "name":      v.get("name",""),
            "baseUrl":   v.get("url",""),
            "latencyMs": v.get("latencyMs", 0),
        })
    resp     = call(enr_port, "/enrich/batch", method="POST", body={"items": items})
    enriched = resp.get("items", [])
    ok(f"Enriched {len(enriched)} APIs")
    for e in enriched[:5]:
        info(f"{e.get('name','?'):40s}  tags={e.get('tags',[])}  sla={e.get('slaTier','?')}")
    return enriched


def step_query_route(router_port, enriched):
    section("Step 4 – QUERY ROUTE  (select Trino cluster)")
    # Simulate a few realistic queries
    queries = [
        "SELECT name, category FROM apis LIMIT 10",
        "SELECT count(*), category FROM apis GROUP BY category ORDER BY count(*) DESC",
        "SELECT * FROM apis WHERE auth = 'none' AND https = true",
    ]
    ok(f"Routing {len(queries)} sample queries")
    for q in queries:
        resp = call(router_port, "/query", method="POST", body={"query": q})
        cluster = resp.get("cluster", "?")
        color   = "cyan" if cluster == "interactive" else "yellow"
        print(f"    {c(color, cluster):20s}  {q[:70]}")
    return True


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    print(c("cyan", "\n╔══════════════════════════════════════════════════╗"))
    print(c("cyan",   "║  Data Platform – End-to-End Smoke Test           ║"))
    print(c("cyan",   "╚══════════════════════════════════════════════════╝"))

    print("\nStarting services …")
    procs = start_services()

    try:
        # Wait for every service to be ready
        for name, port in SERVICES.items():
            wait_ready(name, port)
            ok(f"{name} ready on :{port}")

        disc_port   = SERVICES["api-discovery"]
        val_port    = SERVICES["api-validator"]
        enr_port    = SERVICES["api-enricher"]
        router_port = SERVICES["query-router"]

        apis     = step_discover(disc_port)
        if not apis:
            warn("No APIs discovered – check network or try E2E_SOURCE=apis-guru")
            return 1

        validated = step_validate(val_port, apis)
        enriched  = step_enrich(enr_port, validated)
        step_query_route(router_port, enriched)

        section("Summary")
        ok(f"Discovered : {len(apis)}")
        ok(f"Validated  : {len(validated)}")
        ok(f"Enriched   : {len(enriched)}")
        print(c("green", "\n  All steps completed successfully.\n"))
        return 0

    except urllib.error.URLError as exc:
        print(c("red", f"\n  HTTP error: {exc}"))
        return 1
    except KeyboardInterrupt:
        print("\n  Interrupted.")
        return 0
    finally:
        stop_services(procs)
        print("Services stopped.")


if __name__ == "__main__":
    sys.exit(main())
