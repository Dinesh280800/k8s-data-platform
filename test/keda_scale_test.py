#!/usr/bin/env python3
"""
KEDA Scaling Load Test — publishes fake messages to RabbitMQ queues
so KEDA scales up the target deployments, then drains them to watch scale-down.

Usage:
  python3 test/keda_scale_test.py                    # default: 50 msgs to discovery
  python3 test/keda_scale_test.py --queue api-validator-jobs --count 80
  python3 test/keda_scale_test.py --queue api-enrichment-jobs --count 30
  python3 test/keda_scale_test.py --drain               # purge all queues → scale down

Requirements: RabbitMQ HTTP API reachable at localhost:15672
              kubectl must point at data-platform-cluster
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

RABBIT_API = "http://localhost:15672"
RABBIT_USER = "guest"
RABBIT_PASS = "guest"

QUEUES = {
    "api-discovery-jobs":  ("data-platform", "api-discovery"),
    "api-validator-jobs":  ("data-platform", "api-validator"),
    "api-enrichment-jobs": ("data-platform", "api-enricher"),
}

COLORS = {
    "green":  "\033[92m",
    "yellow": "\033[93m",
    "red":    "\033[91m",
    "cyan":   "\033[96m",
    "reset":  "\033[0m",
}

def c(color, text):
    return f"{COLORS[color]}{text}{COLORS['reset']}"


# ── RabbitMQ helpers ──────────────────────────────────────────────────────────

def _rmq(method, path, body=None):
    url = f"{RABBIT_API}{path}"
    data = json.dumps(body).encode() if body else None
    import base64
    token = base64.b64encode(f"{RABBIT_USER}:{RABBIT_PASS}".encode()).decode()
    req = urllib.request.Request(
        url, data=data,
        headers={"Authorization": f"Basic {token}", "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        print(c("red", f"RabbitMQ HTTP {exc.code}: {exc.read().decode()}"))
        sys.exit(1)


def ensure_queue(queue_name):
    _rmq("PUT", f"/api/queues/%2F/{queue_name}", {"durable": True})


def queue_depth(queue_name):
    info = _rmq("GET", f"/api/queues/%2F/{queue_name}")
    return info.get("messages_ready", 0)


def publish_messages(queue_name, count, payload_template=None):
    body = payload_template or {"job": "fake", "source": "keda-load-test"}
    for i in range(count):
        msg = dict(body, index=i, ts=time.time())
        _rmq("POST", f"/api/exchanges/%2F/amq.default/publish", {
            "routing_key": queue_name,
            "payload": json.dumps(msg),
            "payload_encoding": "string",
            "properties": {"delivery_mode": 2},
        })
    print(c("green", f"  ✓ Published {count} messages → {queue_name}"))


def purge_queue(queue_name):
    _rmq("DELETE", f"/api/queues/%2F/{queue_name}/contents")
    print(c("yellow", f"  ✓ Purged {queue_name}"))


# ── kubectl helpers ───────────────────────────────────────────────────────────

def get_replicas(namespace, deployment):
    out = subprocess.run(
        ["kubectl", "get", "deployment", deployment, "-n", namespace,
         "-o", "jsonpath={.status.readyReplicas}"],
        capture_output=True, text=True,
    )
    val = out.stdout.strip()
    return int(val) if val.isdigit() else 0


def watch_scaling(queue_name, target_ns, target_deploy, duration=180, interval=8):
    print(c("cyan", f"\n  Watching {target_deploy} ({target_ns}) for {duration}s ..."))
    print(f"  {'Time':>6}   {'Queue depth':>12}   {'Replicas':>9}")
    print(f"  {'─'*6}   {'─'*12}   {'─'*9}")
    start = time.monotonic()
    prev_replicas = -1
    while time.monotonic() - start < duration:
        depth = queue_depth(queue_name)
        replicas = get_replicas(target_ns, target_deploy)
        elapsed = int(time.monotonic() - start)
        changed = "  ← scaled!" if replicas != prev_replicas and prev_replicas >= 0 else ""
        color = "green" if replicas > 1 else "reset"
        print(c(color, f"  {elapsed:>5}s   {depth:>12}   {replicas:>9}{changed}"))
        prev_replicas = replicas
        if depth == 0 and elapsed > 30:
            print(c("yellow", "  Queue drained — waiting for cooldown scale-down ..."))
        time.sleep(interval)


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="KEDA RabbitMQ scale test")
    parser.add_argument("--queue", default="api-discovery-jobs",
                        choices=list(QUEUES.keys()), help="Target queue")
    parser.add_argument("--count", type=int, default=50,
                        help="Number of fake messages to publish (default 50)")
    parser.add_argument("--drain", action="store_true",
                        help="Purge all queues without publishing (triggers scale-down)")
    parser.add_argument("--watch", type=int, default=180,
                        help="Seconds to watch scaling (default 180)")
    args = parser.parse_args()

    print(c("cyan", "\n╔══════════════════════════════════════════════════╗"))
    print(c("cyan",   "║  KEDA RabbitMQ Scaling Test                      ║"))
    print(c("cyan",   "╚══════════════════════════════════════════════════╝\n"))

    # ensure queues exist
    for q in QUEUES:
        ensure_queue(q)

    if args.drain:
        print("Draining all queues to trigger scale-down ...")
        for q in QUEUES:
            purge_queue(q)
        print(c("yellow", "\nKEDA cooldownPeriod is 120s — pods will scale down after ~2 min idle."))
        print("Watch with:  kubectl get pods -n data-platform -w")
        return

    queue = args.queue
    ns, deploy = QUEUES[queue]

    print(f"Queue        : {queue}")
    print(f"Deployment   : {deploy} (namespace={ns})")
    print(f"KEDA trigger : scale up when depth > 10, max replicas = 4-6")
    print(f"Messages     : {args.count}")
    print(f"\nCurrent state:")
    print(f"  Queue depth : {queue_depth(queue)}")
    print(f"  Replicas    : {get_replicas(ns, deploy)}")

    print(f"\nPublishing {args.count} messages ...")
    publish_messages(queue, args.count)

    print(f"\nNew queue depth: {queue_depth(queue)}")
    print(c("yellow", "  KEDA polls every 15s — first scale-up in ~15s\n"))

    watch_scaling(queue, ns, deploy, duration=args.watch)

    print(c("cyan", "\nDraining queue to trigger scale-down ..."))
    purge_queue(queue)
    print(c("yellow", "  Cooldown period = 120s — scale-down will happen ~2 min after drain."))
    print("  Continue watching with:  kubectl get pods -n data-platform -w")


if __name__ == "__main__":
    main()
