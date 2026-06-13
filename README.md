# Kubernetes Kind Multi-Node Cluster - Complex Service Deployment

A production-grade Kubernetes learning project deployed locally using **kind** (Kubernetes in Docker). Covers the full lifecycle: cluster creation, application deployment, observability, autoscaling, and reliability patterns.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Kind Cluster                                   │
│                                                                       │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐            │
│  │ Control Plane │  │   Worker 1    │  │   Worker 2    │            │
│  │               │  │ (frontend)    │  │ (backend)     │            │
│  │ • API Server  │  │               │  │               │  ┌────────┐│
│  │ • etcd        │  │ • App Pods    │  │ • App Pods    │  │Worker 3││
│  │ • Scheduler   │  │ • Promtail    │  │ • Promtail    │  │(backend)│
│  │ • Controller  │  │ • Node Exp.   │  │ • Node Exp.   │  │        ││
│  │ • Ingress     │  │               │  │               │  │        ││
│  └───────────────┘  └───────────────┘  └───────────────┘  └────────┘│
│                                                                       │
│  ┌─────────── Monitoring Namespace ──────────────────────┐           │
│  │ Prometheus │ Grafana │ Alertmanager │ Loki │ Promtail │           │
│  └────────────────────────────────────────────────────────┘           │
│                                                                       │
│  ┌─── KEDA Namespace ───┐  ┌─── complex-app Namespace ─────────┐    │
│  │ KEDA Operator         │  │ Deployment (3 replicas)            │    │
│  │ Metrics API Server    │  │ Service + Ingress                  │    │
│  └───────────────────────┘  │ HPA/ScaledObject                   │    │
│                              │ PDB + ConfigMap + Secrets          │    │
│                              └────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

| Tool | Purpose | Install (macOS) |
|------|---------|-----------------|
| Docker or Podman | Container runtime | `brew install --cask docker` or `brew install podman` |
| kind | Local K8s clusters | `brew install kind` |
| kubectl | K8s CLI | `brew install kubectl` |
| helm | Package manager | `brew install helm` |

**System requirements:** ~8GB RAM available, ~20GB disk space.

```bash
# Quick install all prerequisites (macOS)
brew install kind kubectl helm
```

## Quick Start

```bash
# 1. Clone/navigate to this directory
cd k8s-kind-project

# 2. Make scripts executable
chmod +x bootstrap.sh verification/*.sh

# 3. Run full setup (all phases)
./bootstrap.sh

# 4. Verify everything works
./verification/verify.sh

# 5. Test scaling and resilience
./verification/test-scaling.sh
```

## Phased Deployment Plan

### Phase 1: MVP (Cluster + Core App + Basic Monitoring)

```bash
./bootstrap.sh --phase 1    # Create cluster + ingress + metrics-server
./bootstrap.sh --phase 2    # Deploy application
```

**What you get:**
- 4-node kind cluster (1 control-plane + 3 workers)
- NGINX Ingress Controller
- metrics-server (for `kubectl top` and HPA)
- Sample app with 3 replicas, probes, resource limits
- Service + Ingress routing
- HPA for CPU/memory autoscaling
- PodDisruptionBudget

### Phase 2: Observability

```bash
./bootstrap.sh --phase 3    # Deploy Prometheus + Grafana + Loki
```

**What you get:**
- Prometheus (metrics collection, 7-day retention)
- Grafana (dashboards, accessible at `localhost:30000`)
- Alertmanager (alert routing)
- Loki + Promtail (log aggregation)
- PrometheusRule with CPU/error/pod health alerts
- ServiceMonitor for app metrics scraping

### Phase 3: Advanced Autoscaling

```bash
./bootstrap.sh --phase 4    # Deploy KEDA
```

**What you get:**
- KEDA operator
- ScaledObject with multi-trigger scaling (CPU, memory, Prometheus, cron)
- Scale-to-zero capability for queue workers
- TriggerAuthentication patterns

## Project Structure

```
k8s-kind-project/
├── bootstrap.sh                    # Main setup script (run this first)
├── README.md                       # This file
├── kind/
│   └── cluster-config.yaml         # Kind cluster definition (nodes, networking)
├── app/
│   ├── namespace.yaml              # App namespace
│   ├── configmap.yaml              # Application configuration
│   ├── secret.yaml                 # Sensitive configuration
│   ├── deployment.yaml             # Main application (probes, resources, affinity)
│   ├── service.yaml                # Internal load balancer
│   ├── ingress.yaml                # External HTTP routing
│   ├── hpa.yaml                    # Horizontal Pod Autoscaler
│   └── pdb.yaml                    # Pod Disruption Budget
├── monitoring/
│   ├── namespace.yaml              # Monitoring namespace
│   ├── service-monitor.yaml        # Prometheus scrape config for app
│   ├── prometheus/
│   │   ├── values.yaml             # Helm values for kube-prometheus-stack
│   │   └── alert-rules.yaml        # PrometheusRule with alert definitions
│   └── loki/
│       └── values.yaml             # Helm values for Loki + Promtail
├── keda/
│   └── scaled-object.yaml          # KEDA ScaledObject + TriggerAuthentication
└── verification/
    ├── verify.sh                   # Validation checks (run after bootstrap)
    └── test-scaling.sh             # Scaling and resilience tests
```

## Access Points

| Service | URL | Credentials |
|---------|-----|-------------|
| Application | http://complex-app.local | N/A (add to /etc/hosts) |
| Grafana | http://localhost:30000 | admin / admin-password |
| Prometheus | `kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090` | N/A |
| Alertmanager | `kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093` | N/A |

```bash
# Add to /etc/hosts for Ingress to work:
echo "127.0.0.1 complex-app.local" | sudo tee -a /etc/hosts
```

## Key Concepts Demonstrated

### Self-Healing Patterns
- **Liveness Probe**: Detects deadlocked containers → automatic restart
- **Readiness Probe**: Controls traffic routing → unhealthy pods get no traffic
- **Startup Probe**: Handles slow-starting apps → prevents premature kills
- **PDB**: Protects availability during voluntary disruptions (drains, upgrades)
- **Anti-affinity**: Spreads pods across nodes → survives node failure

### Autoscaling
- **HPA**: Scales on CPU/memory utilization (reactive)
- **KEDA**: Scales on external events (queues, custom metrics, cron) + scale-to-zero
- **Behavior tuning**: Stabilization windows prevent flapping

### Observability
- **Metrics**: Prometheus scrapes → stored 7 days → Grafana visualizes
- **Logs**: Promtail collects → Loki stores → query with LogQL
- **Alerts**: PrometheusRule defines conditions → Alertmanager routes notifications

## Environment Customization (Dev → Prod)

| Setting | Dev (current) | Staging | Production |
|---------|---------------|---------|------------|
| Replicas | 3 | 3-5 | 5-20 |
| HPA max | 10 | 20 | 50 |
| CPU request | 100m | 250m | 500m |
| Memory request | 128Mi | 256Mi | 512Mi |
| Prometheus retention | 7d | 15d | 30-90d |
| Loki retention | 72h | 7d | 30d |
| PDB minAvailable | 2 | 3 | N-1 |
| Alertmanager receivers | webhook | Slack | PagerDuty + Slack |
| Secret management | stringData | sealed-secrets | Vault/external-secrets |
| Ingress TLS | disabled | self-signed | cert-manager + Let's Encrypt |

## Useful Commands

```bash
# --- Cluster ---
kubectl get nodes -o wide                          # Node status
kubectl top nodes                                  # Node resource usage

# --- Application ---
kubectl get all -n complex-app                     # All app resources
kubectl top pods -n complex-app                    # Pod resource usage
kubectl logs -n complex-app -l app.kubernetes.io/name=complex-app --tail=50  # Recent logs
kubectl rollout history deployment/complex-app -n complex-app   # Deployment history
kubectl rollout undo deployment/complex-app -n complex-app      # Rollback

# --- Scaling ---
kubectl get hpa -n complex-app -w                  # Watch HPA (live updates)
kubectl get scaledobject -n complex-app            # KEDA status
kubectl describe hpa -n complex-app                # Detailed HPA info

# --- Monitoring ---
kubectl get prometheusrule -n monitoring           # Alert rules
kubectl get servicemonitor -n monitoring           # Scrape configs
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus --tail=20

# --- Debugging ---
kubectl describe pod <pod-name> -n complex-app     # Pod events
kubectl get events -n complex-app --sort-by='.lastTimestamp'  # Recent events
kubectl exec -it <pod-name> -n complex-app -- sh   # Shell into pod

# --- Cleanup ---
./bootstrap.sh --destroy                           # Delete entire cluster
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Pods stuck in Pending | Check `kubectl describe pod` → likely resource constraints. Reduce requests or add nodes. |
| HPA not scaling | Wait 60s for metrics. Check `kubectl describe hpa`. Ensure metrics-server is running. |
| Ingress not working | Verify ingress controller: `kubectl get pods -n ingress-nginx`. Check /etc/hosts entry. |
| Grafana not accessible | Port 30000 may be in use. Change nodePort in values.yaml. |
| Prometheus "no data" | Check ServiceMonitor labels match. Verify app exposes /metrics endpoint. |
| KEDA not scaling | Check ScaledObject status: `kubectl describe scaledobject -n complex-app` |
| Nodes NotReady | Docker/Podman may be resource-constrained. Restart Docker, increase resources. |

## Tear Down

```bash
# Delete the entire cluster (removes everything)
./bootstrap.sh --destroy

# Or manually:
kind delete cluster --name complex-cluster
```
