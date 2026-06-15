# Complete Deployment and Operations Guide

This guide covers the full local setup for the data platform on kind + Podman, including deployment, validation, querying, monitoring, autoscaling, and day-2 operations.

## 1. Platform Summary

The platform flow is:

`API discovery -> RabbitMQ queue -> validation/enrichment -> Postgres -> Trino query layer -> frontend`

Core namespaces:

- `data-platform`: discovery, validator, enricher, query-router
- `messaging`: RabbitMQ
- `store`: Postgres
- `analytics`: Trino coordinator and workers
- `frontend`: frontend UI
- `monitoring`: Prometheus, Alertmanager, Grafana, Loki
- `keda`: KEDA operator

## 2. Prerequisites

Required CLIs:

- kind
- kubectl
- helm
- podman (rootful machine running)

Quick check:

```bash
command -v kind kubectl helm podman
podman info
```

## 3. Environment Sizing

For this project on local kind:

- CPU: 6
- Memory: about 10 GB assigned to Podman machine
- Disk: 60+ GB

Current cluster config is in `cluster/kind-config.yaml`.

## 4. One-Time Host Entries

These hostnames are used by ingress:

- `frontend.local`
- `query.local`
- `prometheus.local`
- `alertmanager.local`

Add once:

```bash
sudo bash -c 'grep -q frontend.local /etc/hosts || echo "127.0.0.1 frontend.local query.local prometheus.local alertmanager.local" >> /etc/hosts'
```

## 5. Create Cluster

```bash
kind create cluster --name data-platform-cluster --config cluster/kind-config.yaml --wait 120s
kubectl config use-context kind-data-platform-cluster
```

Verify nodes:

```bash
kubectl get nodes -o wide
```

## 6. Install Ingress and Metrics Server

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx patch deployment ingress-nginx-controller \
  --type='merge' \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/hostname":"data-platform-cluster-control-plane"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
kubectl wait -n ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
```

## 7. Install Monitoring Stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

kubectl apply -f monitoring/namespace.yaml
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/prometheus/values.yaml \
  --wait \
  --timeout 10m

helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --values monitoring/loki/values.yaml \
  --wait \
  --timeout 5m

kubectl apply -f monitoring/ingress.yaml
```

## 8. Install KEDA

```bash
helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --wait \
  --timeout 5m
```

## 9. Build and Load Service Images (Podman + kind)

Build:

```bash
podman build -t data-platform/api-discovery:local -f services/api-discovery/Dockerfile .
podman build -t data-platform/api-validator:local -f services/api-validator/Dockerfile .
podman build -t data-platform/api-enricher:local -f services/api-enricher/Dockerfile .
podman build -t data-platform/query-router:local -f services/query-router/Dockerfile .
```

Load into kind:

```bash
for img in api-discovery api-validator api-enricher query-router; do
  podman save data-platform/${img}:local -o /tmp/${img}.tar
  KIND_EXPERIMENTAL_PROVIDER=podman kind load image-archive /tmp/${img}.tar --name data-platform-cluster
  rm -f /tmp/${img}.tar
done
```

## 10. Deploy Platform Components

```bash
kubectl apply -f services/namespace.yaml
kubectl apply -f platform/broker/k8s.yaml
kubectl apply -f platform/store/k8s.yaml
kubectl apply -f platform/query/trino.yaml

kubectl apply -f services/api-discovery/k8s.yaml
kubectl apply -f services/api-validator/k8s.yaml
kubectl apply -f services/api-enricher/k8s.yaml
kubectl apply -f services/query-router/k8s.yaml
kubectl apply -f services/frontend/k8s.yaml

kubectl apply -f keda/scaled-object.yaml
kubectl apply -f monitoring/platform-service-monitor.yaml
kubectl apply -f monitoring/platform-prometheus-rules.yaml
```

Wait for readiness:

```bash
kubectl get pods -n messaging
kubectl get pods -n store
kubectl get pods -n analytics
kubectl get pods -n data-platform
kubectl get pods -n frontend
```

## 11. Access URLs

- Frontend: `http://frontend.local`
- Query Router: `http://query.local`
- Trino UI: `http://localhost:8080/ui/`
- Grafana: `http://localhost:3000`
- RabbitMQ UI: `http://localhost:15672`
- Prometheus: `http://prometheus.local`
- Alertmanager: `http://alertmanager.local`

Credentials:

- RabbitMQ: `guest` / `guest`
- Grafana: `admin` / `admin-password`
- Postgres: `platform` / `platform123` database `apis`

## 12. Querying Data

### 12.1 Through frontend/query-router

Example request:

```bash
curl -sS -X POST http://query.local/query \
  -H 'Content-Type: application/json' \
  -d '{"query":"SELECT api_id, name, source FROM postgresql.catalog.apis ORDER BY api_id DESC LIMIT 10","maxRows":100}'
```

### 12.2 Through Trino UI

Run:

```sql
SHOW TABLES FROM postgresql.catalog;
SELECT * FROM postgresql.catalog.apis LIMIT 20;
SELECT source, count(*) FROM postgresql.catalog.apis GROUP BY source;
```

### 12.3 Direct Postgres

```bash
kubectl port-forward -n store svc/postgres 5432:5432
```

Connect with any Postgres client:

- host: `localhost`
- port: `5432`
- database: `apis`
- user: `platform`
- password: `platform123`

## 13. Seed Test Data

```bash
POSTGRES_POD=$(kubectl get pod -n store -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n store "$POSTGRES_POD" -- sh -lc "psql -U platform -d apis <<'SQL'
INSERT INTO catalog.apis (name, base_url, source) VALUES
('jsonplaceholder-posts','https://jsonplaceholder.typicode.com/posts','jsonplaceholder'),
('jsonplaceholder-users','https://jsonplaceholder.typicode.com/users','jsonplaceholder'),
('openlibrary-search','https://openlibrary.org/search.json','openlibrary')
ON CONFLICT DO NOTHING;
SELECT api_id, name, source, discovered_at FROM catalog.apis ORDER BY api_id DESC LIMIT 10;
SQL"
```

## 14. KEDA Queue-Based Scaling Test

Create queues:

```bash
bash test/create-queues.sh
```

Run scale test:

```bash
python3 test/keda_scale_test.py --queue api-discovery-jobs --count 50 --watch 200
```

What to expect:

- Queue depth rises above 10
- `api-discovery` scales from 1 up to 4 replicas
- After queue purge and 120s cooldown, scales back down

Watch pods:

```bash
kubectl get pods -n data-platform -w
```

## 15. Day-2 Operations

Restart one component:

```bash
kubectl rollout restart deployment/query-router -n data-platform
kubectl rollout status deployment/query-router -n data-platform --timeout=180s
```

Scale Trino workers:

```bash
kubectl scale deployment/trino-workers -n analytics --replicas=2
kubectl get pods -n analytics -w
```

Check queue depth:

```bash
curl -sS -u guest:guest http://localhost:15672/api/queues/%2F | python3 -c "import sys,json; [print(f'{q[\"name\"]}: ready={q.get(\"messages_ready\",0)}') for q in json.load(sys.stdin)]"
```

## 16. Clean Teardown

Delete platform namespaces:

```bash
kubectl delete namespace data-platform messaging analytics frontend store keda monitoring --ignore-not-found=true
```

Delete kind cluster (Podman):

```bash
KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name data-platform-cluster
```

One-command reset:

```bash
./reset-cluster.sh
```

## 17. Observability Stack

### 17.1 Custom Application Metrics

Each service exposes `/metrics` with these custom Prometheus metrics:

| Metric | Type | Description |
|---|---|---|
| `service_requests_total` | counter | All HTTP requests |
| `business_requests_total` | counter | Requests processed by business logic |
| `service_errors_total` | counter | Unhandled exceptions |
| `service_in_flight_requests` | gauge | Currently processing requests |
| `service_uptime_seconds` | gauge | Time since pod started |
| `service_request_duration_seconds` | histogram | Latency distribution (11 buckets: 5ms to 10s) |
| `service_path_requests_total` | counter | Per-path hit counter |
| `health_checks_total` | counter | Liveness probe hits |
| `ready_checks_total` | counter | Readiness probe hits |

### 17.2 Infrastructure Metrics (auto-collected)

- **node-exporter**: CPU, memory, disk, network per node
- **kube-state-metrics**: pod status, deployment replicas, restarts, OOM kills
- **kubelet/cAdvisor**: container-level CPU and memory per pod

### 17.3 Grafana Dashboard

Auto-loaded via ConfigMap sidecar. View at:

- http://localhost:3000 → Dashboards → "Data Platform Overview"

Dashboard panels:
- Request rate per service
- Business request rate
- Error rate
- P50/P95/P99 latency histogram
- In-flight requests gauge
- Service uptime
- Pod CPU and memory
- Node CPU and memory
- Deployment replica count
- Pod restart count

### 17.4 PromQL Learning Queries

Open http://prometheus.local and try:

```promql
# Request rate per service
sum by (service) (rate(service_requests_total[5m]))

# P95 latency
histogram_quantile(0.95, sum by (le, service) (rate(service_request_duration_seconds_bucket[5m])))

# Error ratio
sum by (service) (rate(service_errors_total[5m])) / sum by (service) (rate(service_requests_total[5m]))

# Pod CPU
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="data-platform",container!=""}[5m]))

# Node memory percent
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes

# Deployment replicas
kube_deployment_status_replicas_available{namespace="data-platform"}
```

### 17.5 Alert Rules

Defined in `monitoring/platform-prometheus-rules.yaml`:

| Alert | Fires when |
|---|---|
| ServiceHighErrorRate | errors/s > 0.1 for 2m |
| ServiceHighLatencyP95 | p95 > 2s for 3m |
| ServiceDown | scrape target unreachable for 1m |
| PodRestarting | restart rate > 0 for 5m |
| QueueDepthHigh | RabbitMQ queue > 100 for 5m |
| NodeHighCPU | > 85% for 5m |
| NodeHighMemory | > 90% for 5m |
| PersistentVolumeAlmostFull | PV < 10% free for 5m |

### 17.6 Email Alerting

Configured in `monitoring/prometheus/values.yaml` under `alertmanager.config`.

To activate:

1. Generate Gmail App Password at https://myaccount.google.com/apppasswords
2. Edit values file:
   - `smtp_from`: your Gmail
   - `smtp_auth_username`: your Gmail
   - `smtp_auth_password`: 16-char app password
   - `to`: destination email in receivers
3. Apply:

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --values monitoring/prometheus/values.yaml --timeout 5m
```

Test with a manual alert:

```bash
curl -X POST http://alertmanager.local/api/v1/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestEmail","severity":"warning","namespace":"data-platform"},"annotations":{"summary":"Test email alert"}}]'
```

### 17.7 Logging with Loki

Logs are collected by Promtail (DaemonSet) and stored in Loki.

Services emit structured JSON logs:

```json
{"ts":"2026-06-15T08:30:00Z","level":"info","service":"query-router","msg":"business_request","path":"/query","method":"POST"}
```

Query in Grafana → Explore → Loki datasource:

```logql
# All data-platform logs
{namespace="data-platform"}

# Specific service
{namespace="data-platform"} | json | service="query-router"

# Errors only
{namespace="data-platform"} | json | level="error"

# Business requests
{namespace="data-platform"} | json | msg="business_request"

# Rate of errors per service
sum by (service) (rate({namespace="data-platform"} | json | level="error" [5m]))
```

### 17.8 Prometheus Targets (kind-specific)

In kind, these control-plane targets are always down (expected):

- kube-controller-manager
- kube-scheduler
- kube-etcd
- kube-proxy

These are disabled in `monitoring/prometheus/values.yaml`:

```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false
```

## 18. File Map

- `cluster/kind-config.yaml`: kind topology and host port mappings
- `bootstrap.sh`: full bootstrap automation
- `bootstrap-data-platform.sh`: app/platform-only apply and delete
- `build-images.sh`: image build/load helper
- `reset-cluster.sh`: one-command teardown and recreate
- `setup-hosts.sh`: /etc/hosts configuration
- `monitoring/ingress.yaml`: direct access for Prometheus/Alertmanager
- `monitoring/grafana-dashboard.yaml`: auto-loaded Grafana dashboard
- `monitoring/platform-prometheus-rules.yaml`: alert rules
- `monitoring/platform-service-monitor.yaml`: ServiceMonitor for app services
- `keda/scaled-object.yaml`: KEDA triggers
- `test/keda_scale_test.py`: fake queue load test for KEDA
- `test/create-queues.sh`: queue bootstrap helper
- `test/e2e_smoke.py`: end-to-end pipeline test
- `services/common/app_server.py`: shared HTTP server with metrics, logging, CORS
