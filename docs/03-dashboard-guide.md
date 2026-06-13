# Grafana Dashboard Guide

## Prerequisites

- Monitoring stack deployed (Phase 3 of bootstrap)
- Grafana accessible via port-forward:
  ```bash
  kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
  ```
- Login: `admin` / password from `kubectl get secret monitoring-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d`

---

## Datasources (Pre-configured)

| Datasource | URL | Purpose |
|------------|-----|---------|
| Prometheus | `http://monitoring-kube-prometheus-prometheus:9090` | Metrics (CPU, memory, request rates) |
| Loki | `http://loki.monitoring.svc.cluster.local:3100` | Logs (container stdout/stderr) |
| Alertmanager | `http://monitoring-kube-prometheus-alertmanager:9093` | Active alerts |

These are auto-configured by the Helm chart. You can verify at:
**Grafana → Configuration (gear icon) → Data sources**

---

## Creating Your First Dashboard

### Method 1: Through the UI

1. Click **"+" → "New Dashboard"**
2. Click **"Add visualization"**
3. Select **"Prometheus"** as data source
4. Enter a PromQL query (examples below)
5. Click **"Apply"**
6. Click **"Save"** (floppy disk icon)

### Method 2: Import Pre-built Dashboards

1. Click **"+" → "Import"**
2. Enter a dashboard ID from [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards):

| Dashboard ID | Name | Purpose |
|-------------|------|---------|
| 15760 | Kubernetes / Views / Pods | Pod resource usage |
| 14205 | Kubernetes / Views / Namespaces | Namespace overview |
| 1860 | Node Exporter Full | Host metrics |
| 13332 | kube-state-metrics | K8s object states |
| 12006 | Kubernetes API Server | API server health |

3. Select **"Prometheus"** as the data source → Click **"Import"**

---

## Example Panels for complex-app

### Panel 1: Pod CPU Usage

**Query (PromQL):**
```promql
sum(rate(container_cpu_usage_seconds_total{namespace="complex-app", container!=""}[5m])) by (pod)
```

**Panel settings:**
- Visualization: Time series
- Legend: `{{pod}}`
- Unit: `percent (0.0-1.0)`
- Thresholds: 0.7 (yellow), 0.9 (red)

---

### Panel 2: Pod Memory Usage

**Query:**
```promql
sum(container_memory_working_set_bytes{namespace="complex-app", container!=""}) by (pod) / 1024 / 1024
```

**Panel settings:**
- Visualization: Time series
- Legend: `{{pod}}`
- Unit: `megabytes`

---

### Panel 3: HTTP Request Rate

**Query:**
```promql
sum(rate(http_requests_total{namespace="complex-app"}[2m])) by (status)
```

**Panel settings:**
- Visualization: Time series
- Legend: `Status {{status}}`
- Unit: `requests/sec`

---

### Panel 4: HTTP Error Rate (%)

**Query:**
```promql
sum(rate(http_requests_total{namespace="complex-app", status=~"5.."}[5m]))
/
sum(rate(http_requests_total{namespace="complex-app"}[5m]))
* 100
```

**Panel settings:**
- Visualization: Stat or Gauge
- Unit: `percent (%)`
- Thresholds: 1 (yellow), 5 (red)

---

### Panel 5: Pod Restarts

**Query:**
```promql
sum(increase(kube_pod_container_status_restarts_total{namespace="complex-app"}[1h])) by (pod)
```

**Panel settings:**
- Visualization: Table or Stat
- Unit: `short`
- Thresholds: 1 (yellow), 3 (red)

---

### Panel 6: HPA Current vs Desired Replicas

**Query 1 (current):**
```promql
kube_deployment_status_replicas{namespace="complex-app", deployment="complex-app"}
```

**Query 2 (desired):**
```promql
kube_deployment_spec_replicas{namespace="complex-app", deployment="complex-app"}
```

**Panel settings:**
- Visualization: Time series
- Legend: "Current replicas" / "Desired replicas"

---

### Panel 7: Network Traffic

**Query (received):**
```promql
sum(rate(container_network_receive_bytes_total{namespace="complex-app"}[5m])) by (pod) / 1024
```

**Panel settings:**
- Visualization: Time series
- Unit: `KiB/s`

---

## Loki Log Panels

### Panel 8: Recent Error Logs

**Query (LogQL):**
```logql
{namespace="complex-app"} |= "error"
```

**Panel settings:**
- Visualization: Logs
- Data source: Loki

### Panel 9: Log Volume Over Time

**Query:**
```logql
sum(count_over_time({namespace="complex-app"}[5m])) by (pod)
```

**Panel settings:**
- Visualization: Time series
- Data source: Loki

---

## Creating a Complete Dashboard (JSON Model)

Save this as a ConfigMap to auto-provision the dashboard:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: complex-app-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"          # Sidecar picks this up automatically
data:
  complex-app.json: |
    {
      "dashboard": {
        "title": "Complex App Overview",
        "panels": [
          {
            "title": "CPU Usage by Pod",
            "type": "timeseries",
            "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
            "targets": [{
              "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"complex-app\", container!=\"\"}[5m])) by (pod)",
              "legendFormat": "{{pod}}"
            }],
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          },
          {
            "title": "Memory Usage by Pod",
            "type": "timeseries",
            "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8},
            "targets": [{
              "expr": "sum(container_memory_working_set_bytes{namespace=\"complex-app\", container!=\"\"}) by (pod) / 1024 / 1024",
              "legendFormat": "{{pod}}"
            }],
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          },
          {
            "title": "Pod Restarts (1h)",
            "type": "stat",
            "gridPos": {"x": 0, "y": 8, "w": 6, "h": 4},
            "targets": [{
              "expr": "sum(increase(kube_pod_container_status_restarts_total{namespace=\"complex-app\"}[1h]))"
            }],
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          },
          {
            "title": "Replica Count",
            "type": "stat",
            "gridPos": {"x": 6, "y": 8, "w": 6, "h": 4},
            "targets": [{
              "expr": "kube_deployment_status_available_replicas{namespace=\"complex-app\", deployment=\"complex-app\"}"
            }],
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "schemaVersion": 38,
        "version": 1
      }
    }
EOF
```

After applying, the dashboard appears in Grafana under **Dashboards → Browse** within ~30 seconds (the sidecar auto-detects it).

---

## Common Grafana Operations

| Task | Steps |
|------|-------|
| Add a panel | Dashboard → Edit → Add visualization |
| Set alerts in Grafana | Panel → Alert tab → Create alert rule |
| Share a dashboard | Dashboard → Share icon → Export JSON |
| Variables (dropdowns) | Dashboard Settings → Variables → Add (e.g., namespace picker) |
| Annotations | Dashboard Settings → Annotations → Add (mark deployments on graphs) |

---

## Useful PromQL Queries Cheat Sheet

```promql
# Cluster-wide
sum(kube_pod_status_phase{phase="Running"})                     # Total running pods
sum(kube_node_status_allocatable{resource="cpu"})               # Total allocatable CPU
sum(kube_node_status_allocatable{resource="memory"}) / 1024^3   # Total allocatable memory (GiB)

# Per-namespace
count(kube_pod_info{namespace="complex-app"})                    # Pod count
sum(kube_pod_container_resource_requests{namespace="complex-app", resource="cpu"})  # Total CPU requests

# Performance
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))  # P95 latency
sum(rate(http_requests_total[5m]))                               # Total RPS across all pods
```
