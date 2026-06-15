# Kubernetes Data Platform for Local Mac

A lightweight local Kubernetes scaffold for API discovery, queue-based ingestion, SQL storage, Trino querying, monitoring, dashboards, and autoscaling.

## Flow

`api discovery -> broker -> postgres tables -> trino query layer -> frontend -> monitoring/logging -> grafana dashboards -> keda/hpa`

## What lives where

- `cluster/` - Kind cluster configuration for local Mac
- `services/` - API services and the frontend
- `platform/broker/` - RabbitMQ broker for async work
- `platform/store/` - Postgres schema and tables
- `platform/query/` - Trino coordinator and worker scaffold
- `monitoring/` - Prometheus, Grafana, Loki, and alert rules
- `keda/` - autoscaling definitions
- `bootstrap.sh` - one command to create the cluster and deploy the platform
- `bootstrap-data-platform.sh` - applies only the platform layer

## Local Mac sizing

Recommended starting point:

- 4 CPU
- 6 to 8 GB RAM
- 40 to 70 GB disk

For a lightweight local setup, keep the cluster small and start with 1 coordinator + 1 worker for Trino.

## Quick start

```bash
cd /Users/ds/Downloads/Learnings/k8s-data-platform
chmod +x bootstrap.sh bootstrap-data-platform.sh
./bootstrap.sh
```

If you want only the lighter core stack on a small Mac, skip the heavier layers:

```bash
SKIP_MONITORING=1 SKIP_KEDA=1 ./bootstrap.sh
```

## Manual phases

```bash
# Cluster only
kind create cluster --name data-platform-cluster --config cluster/kind-config.yaml

# Platform only
./bootstrap-data-platform.sh apply

# Teardown
./bootstrap-data-platform.sh delete
kind delete cluster --name data-platform-cluster
```

## Service groups

### Services

- API discovery crawls public API directories, GitHub OpenAPI files, and endpoint sources.
- API validator checks availability, latency, and basic response health.
- API enricher adds tags, categories, and metadata.
- Query router decides whether a query should go to Trino or be handled by the app layer.
- Frontend is a simple UI entry point.

### Platform

- RabbitMQ buffers ingestion work so API crawlers do not hit the database directly.
- Postgres stores APIs, endpoints, health checks, and metadata in schema tables.
- Trino queries Postgres and can later be expanded to multiple query clusters.

### Monitoring

- Prometheus scrapes service metrics.
- Loki collects logs.
- Grafana dashboards show platform health, queue depth, Trino load, and API throughput.
- Alert rules flag API failures, queue growth, and query backlog.

### Autoscaling

- HPA scales on CPU and memory.
- KEDA scales workers on queue depth.

## Notes

- Replace `ghcr.io/YOUR_ORG/...` images with real builds before running end-to-end.
- This is intentionally lightweight for local Mac development.
- If you want separate Trino clusters later, add a second coordinator/worker set under `platform/query/` and route users by workload class.

## Documentation

- `docs/complete-deployment-and-operations-guide.md` - full step-by-step deployment, validation, querying, monitoring, and autoscaling operations.
- `docs/troubleshooting-guide.md` - symptom-based troubleshooting with direct fix commands.
- `docs/data-platform-architecture.md` - architecture and namespace overview.
