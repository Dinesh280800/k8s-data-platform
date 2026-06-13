# Architecture & YAML File Guide

## System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              YOUR MACHINE (macOS)                            │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    Podman Machine (Linux VM)                         │    │
│  │                                                                     │    │
│  │  ┌───────────────────────────────────────────────────────────────┐  │    │
│  │  │              Kind Cluster ("complex-cluster")                  │  │    │
│  │  │                                                               │  │    │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │  │    │
│  │  │  │Control Plane │  │  Worker 1   │  │  Worker 2   │          │  │    │
│  │  │  │             │  │             │  │             │          │  │    │
│  │  │  │ API Server  │  │ App Pods    │  │ App Pods    │          │  │    │
│  │  │  │ etcd        │  │ Promtail    │  │ Promtail    │          │  │    │
│  │  │  │ Scheduler   │  │ Node Export │  │ Node Export │          │  │    │
│  │  │  │ Ingress     │  │             │  │             │          │  │    │
│  │  │  └─────────────┘  └─────────────┘  └─────────────┘          │  │    │
│  │  │                                                               │  │    │
│  │  │  Namespaces:                                                  │  │    │
│  │  │  ├── complex-app    → Your application lives here             │  │    │
│  │  │  ├── monitoring     → Prometheus, Grafana, Loki, Alertmanager │  │    │
│  │  │  ├── keda           → KEDA autoscaler operator                │  │    │
│  │  │  ├── ingress-nginx  → Ingress controller                     │  │    │
│  │  │  └── kube-system    → Core K8s components                    │  │    │
│  │  └───────────────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  Access Points:                                                             │
│  • kubectl commands → API Server                                           │
│  • localhost:3000   → Grafana (via port-forward)                           │
│  • localhost:9090   → Prometheus (via port-forward)                        │
│  • localhost:80     → App via Ingress (with /etc/hosts entry)              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## How Components Connect

```
User Request → Ingress Controller → Service → Pod (container)
                                                    ↓
                                              Prometheus scrapes /metrics
                                                    ↓
                                              Grafana reads from Prometheus
                                                    ↓
                                              Alert Rules evaluate conditions
                                                    ↓
                                              Alertmanager sends notifications

Promtail (on each node) → collects stdout/stderr from all containers → sends to Loki
KEDA → watches Prometheus metrics / external events → adjusts pod count
```

---

## File-by-File Explanation

### 1. `kind/cluster-config.yaml` — The Cluster Blueprint

**What it does:** Tells `kind` (Kubernetes in Docker) how to create your local cluster — how many nodes, what ports to expose, and network settings.

**Analogy:** This is like the floor plan for a building. You're deciding how many rooms (nodes) you need and where the doors (ports) are.

```yaml
kind: Cluster                          # ← WHAT: Type of resource (always "Cluster" for kind)
apiVersion: kind.x-k8s.io/v1alpha4     # ← WHAT: API version (kind uses its own API)

networking:
  podSubnet: "10.244.0.0/16"          # ← IP range for pods (like an internal phone extension system)
  serviceSubnet: "10.96.0.0/12"       # ← IP range for services (stable addresses for groups of pods)
  disableDefaultCNI: false            # ← Use built-in networking (kindnet)

nodes:
  - role: control-plane               # ← This node runs the "brain" of the cluster
    extraPortMappings:
      - containerPort: 80             # ← Container port 80...
        hostPort: 80                  # ← ...mapped to your Mac's port 80 (for web traffic)
        protocol: TCP

  - role: worker                      # ← This node runs your application workloads
    labels:
      tier: frontend                  # ← Custom label (used for scheduling preferences)
```

**Key Concept:** Control plane = management. Workers = where your apps actually run.

---

### 2. `app/namespace.yaml` — Creating a Room for Your App

**What it does:** Creates an isolated space (namespace) where all your app's resources live. Like creating a project folder.

```yaml
apiVersion: v1                         # ← Core Kubernetes API
kind: Namespace                        # ← Resource type: a namespace
metadata:
  name: complex-app                    # ← Name used in all other files (namespace: complex-app)
  labels:
    app.kubernetes.io/name: complex-app  # ← Standard label for identification
    environment: dev                     # ← Custom label: dev, staging, or prod
```

**Why it matters:** Without a namespace, everything goes into "default" and gets messy. Namespaces let you:
- Isolate resources between teams/projects
- Apply resource quotas per namespace
- Delete everything in one command: `kubectl delete namespace complex-app`

---

### 3. `app/configmap.yaml` — Application Settings

**What it does:** Stores non-sensitive configuration that your app reads. Like a `.env` file but managed by Kubernetes.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config                     # ← Referenced by the Deployment
  namespace: complex-app               # ← Must match the Deployment's namespace
data:
  APP_PORT: "8080"                     # ← Each key becomes an environment variable in the pod
  DB_HOST: "postgres-service..."       # ← Service DNS name (Kubernetes auto-creates DNS)
  LOG_LEVEL: "info"                    # ← Your app reads this at runtime
  
  nginx.conf: |                        # ← Multi-line value (mounted as a file)
    server {
      listen 8080;
      ...
    }
```

**How the app reads it:** The Deployment references this ConfigMap via `envFrom` (all keys as env vars) or `volumeMounts` (mount a key as a file).

---

### 4. `app/secret.yaml` — Sensitive Configuration

**What it does:** Same as ConfigMap but for passwords, API keys, tokens. Values are base64-encoded (NOT encrypted — just obscured).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: complex-app
type: Opaque                           # ← Generic secret type
stringData:                            # ← Plain text (K8s converts to base64 automatically)
  DB_PASSWORD: "change-me-in-prod"     # ← Injected as env var DB_PASSWORD in the container
  JWT_SECRET: "jwt-signing-secret..."
```

**Security warning:** In production, use:
- `sealed-secrets` (encrypts before storing in git)
- `external-secrets-operator` (pulls from AWS Secrets Manager, HashiCorp Vault, etc.)
- NEVER commit real secrets to git

---

### 5. `app/deployment.yaml` — The Main Application (Most Important File)

**What it does:** Defines WHAT container to run, HOW MANY copies, and HOW to manage them. This is where 80% of the complexity lives.

**Structure breakdown:**

```yaml
apiVersion: apps/v1                    # ← Apps API group
kind: Deployment                       # ← Creates and manages ReplicaSets → which manage Pods
metadata:
  name: complex-app                    # ← Deployment name (used by HPA, Service, etc.)
  namespace: complex-app
```

**Spec section (desired state):**

```yaml
spec:
  replicas: 3                          # ← Run 3 identical copies of this app
  
  selector:                            # ← HOW the Deployment finds its pods
    matchLabels:
      app.kubernetes.io/name: complex-app
  
  strategy:                            # ← HOW to update (rolling = gradual replacement)
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1                      # ← During update: create 1 extra pod
      maxUnavailable: 0                # ← During update: never have fewer than 3 running
```

**Pod template (what each replica looks like):**

```yaml
  template:
    spec:
      securityContext:
        runAsNonRoot: true             # ← Security: don't run as root user
        runAsUser: 1000                # ← Run as UID 1000 instead

      containers:
        - name: app
          image: nginx:1.25-alpine     # ← Container image (replace with your app)
          
          resources:
            requests:                  # ← Minimum guaranteed resources
              cpu: 100m                #    (100 millicores = 10% of 1 CPU)
              memory: 128Mi            #    (128 megabytes)
            limits:                    # ← Maximum allowed (killed if memory exceeded)
              cpu: 500m
              memory: 256Mi
          
          livenessProbe:               # ← "Is the app alive?" If no → restart container
            httpGet:
              path: /health
              port: http
            periodSeconds: 15
          
          readinessProbe:              # ← "Can the app serve traffic?" If no → stop sending requests
            httpGet:
              path: /ready
              port: http
            periodSeconds: 5
```

**Visual: Pod lifecycle**
```
Pod Created → Startup Probe passes → Readiness Probe passes → Receives traffic
                                                                      ↓
                                              Liveness Probe fails 3x → Container restarted
                                              Readiness Probe fails 3x → Removed from traffic
```

---

### 6. `app/service.yaml` — Internal Load Balancer

**What it does:** Creates a stable network address (DNS name + IP) that routes traffic to your pods. Pods come and go, but the Service address stays constant.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: complex-app-service            # ← DNS: complex-app-service.complex-app.svc.cluster.local
  namespace: complex-app
spec:
  type: ClusterIP                      # ← Internal only (not accessible from outside cluster)
  selector:                            # ← Routes to pods matching these labels
    app.kubernetes.io/name: complex-app
  ports:
    - name: http
      port: 80                         # ← Service listens on port 80
      targetPort: http                 # ← Forwards to container port named "http" (8080)
```

**Analogy:** A Service is like a phone directory entry. You call "complex-app-service" and it connects you to any available pod.

---

### 7. `app/ingress.yaml` — External Access Point

**What it does:** Exposes your Service to the outside world via HTTP/HTTPS. Maps domain names + URL paths to backend Services.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: complex-app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /   # ← URL rewriting rule
spec:
  ingressClassName: nginx              # ← Which Ingress Controller handles this
  rules:
    - host: complex-app.local          # ← Domain name (add to /etc/hosts)
      http:
        paths:
          - path: /                    # ← URL path
            pathType: Prefix
            backend:
              service:
                name: complex-app-service   # ← Route to this Service
                port:
                  name: http
```

**Traffic flow:** `Browser → complex-app.local:80 → Ingress Controller → Service → Pod`

---

### 8. `app/hpa.yaml` — Auto-Scaling Rules

**What it does:** Automatically adjusts the number of pods based on CPU/memory usage. More traffic → more pods. Less traffic → fewer pods.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: complex-app-hpa
spec:
  scaleTargetRef:
    kind: Deployment
    name: complex-app                  # ← WHAT to scale
  minReplicas: 2                       # ← Never fewer than 2 (high availability)
  maxReplicas: 10                      # ← Never more than 10 (cost ceiling)
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70       # ← Scale up when avg CPU > 70%
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # ← Wait 5 min before scaling down (prevent flapping)
```

**Formula:** `desired = ceil(current × (actual_metric / target_metric))`
Example: 3 pods at 90% CPU → `ceil(3 × 90/70)` = 4 pods needed

---

### 9. `app/pdb.yaml` — Disruption Protection

**What it does:** Prevents Kubernetes from killing too many pods at once during maintenance (node drains, cluster upgrades).

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: 2                      # ← Always keep at least 2 pods running
  selector:
    matchLabels:
      app.kubernetes.io/name: complex-app
```

**When it activates:** Cluster admin runs `kubectl drain node-1` → PDB says "you can only evict 1 pod at a time, keep 2 running."

---

### 10. `monitoring/prometheus/values.yaml` — Monitoring Stack Config

**What it does:** Configures the Helm chart that installs Prometheus (metrics), Grafana (dashboards), and Alertmanager (alerts).

Key sections:
- `prometheus.prometheusSpec` → Data retention, storage, scrape configs
- `grafana` → Admin password, datasources, dashboard sidecar
- `alertmanager.config` → Where to send alerts (Slack, webhook, email)

---

### 11. `monitoring/prometheus/alert-rules.yaml` — Alert Definitions

**What it does:** Defines conditions that trigger alerts. When a PromQL expression is true for a specified duration, an alert fires.

```yaml
- alert: HighCPUUsage
  expr: |                              # ← PromQL query
    (cpu_usage / cpu_request) > 0.8    #    "Is CPU above 80%?"
  for: 5m                             # ← Must be true for 5 minutes (prevents blips)
  labels:
    severity: warning                  # ← Used for routing (warning vs critical)
  annotations:
    description: "Pod {{ $labels.pod }} CPU is above 80%"
```

---

### 12. `keda/scaled-object.yaml` — Event-Driven Auto-Scaling

**What it does:** Like HPA on steroids — scales based on external events (message queues, custom Prometheus metrics, cron schedules) and can scale to zero.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
spec:
  scaleTargetRef:
    kind: Deployment
    name: complex-app
  minReplicaCount: 2
  maxReplicaCount: 15
  triggers:
    - type: prometheus                 # ← Scale based on Prometheus metric
      metadata:
        query: sum(rate(http_requests_total[2m]))
        threshold: "100"               # ← Scale up when RPS > 100
    - type: cron                       # ← Pre-scale during business hours
      metadata:
        start: "0 8 * * 1-5"
        desiredReplicas: "5"
```

---

## Relationship Map

```
namespace.yaml ─── creates the "room" where everything lives
     │
     ├── configmap.yaml ──┐
     ├── secret.yaml ─────┼── deployment.yaml reads these for configuration
     │                     │
     ├── deployment.yaml ──┼── creates Pods (your running application)
     │        │            │
     │        ├── service.yaml ── provides stable access to Pods
     │        │       │
     │        │       └── ingress.yaml ── exposes Service to outside world
     │        │
     │        ├── hpa.yaml ── scales Deployment up/down based on metrics
     │        └── pdb.yaml ── protects Pods during maintenance
     │
     └── keda/scaled-object.yaml ── advanced autoscaling (replaces HPA)

monitoring/
     ├── prometheus values ── scrapes metrics from all pods
     ├── alert-rules.yaml ── defines when to fire alerts
     ├── service-monitor.yaml ── tells Prometheus what to scrape
     └── loki values ── collects logs from all pods
```
