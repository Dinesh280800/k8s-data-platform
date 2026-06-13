# Deployment Guide

## Prerequisites

| Tool | Purpose | Install (macOS) | Verify |
|------|---------|-----------------|--------|
| Podman | Container runtime | `brew install podman` | `podman --version` |
| kind | Local K8s clusters | `brew install kind` | `kind version` |
| kubectl | K8s command-line tool | `brew install kubectl` | `kubectl version --client` |
| Helm | K8s package manager | `brew install helm` | `helm version` |
| git | Version control | Pre-installed on macOS | `git --version` |

### Podman Machine Setup

```bash
# Create a podman machine with sufficient resources
podman machine init --cpus 4 --memory 8192 --disk-size 70
podman machine start

# Verify
podman info
```

---

## Part A: Deploy the Current Service (complex-app)

### Step 1: Create the Cluster

```bash
cd k8s-kind-project
chmod +x bootstrap.sh verification/*.sh

# Create cluster (Phase 1)
./bootstrap.sh --phase 1
```

**What happens:** Creates a Kind cluster with 1 control-plane + 2 worker nodes, installs NGINX Ingress Controller and metrics-server.

**Verify:**
```bash
kubectl get nodes          # Should show 3 nodes: Ready
kubectl cluster-info       # Shows API server URL
```

### Step 2: Deploy the Application

```bash
./bootstrap.sh --phase 2
```

**What happens:** Creates namespace, ConfigMap, Secret, Deployment (3 replicas), Service, Ingress, HPA, PDB.

**Verify:**
```bash
kubectl get pods -n complex-app          # 3 pods: Running, 1/1 Ready
kubectl get svc -n complex-app           # Service with ClusterIP
kubectl get ingress -n complex-app       # Ingress with rules
```

### Step 3: Deploy Monitoring

```bash
./bootstrap.sh --phase 3
```

**Verify:**
```bash
kubectl get pods -n monitoring           # All pods Running
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80  # Access Grafana
```

### Step 4: Deploy KEDA

```bash
./bootstrap.sh --phase 4
```

**Verify:**
```bash
kubectl get pods -n keda                 # KEDA operator Running
kubectl get scaledobject -n complex-app  # ScaledObject Ready=True
```

---

## Part B: Deploy a NEW Different Service

This is a repeatable template for deploying any additional service to the same cluster.

### Example: Deploying a Python API Service

#### Step 1: Create the Namespace

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: my-new-service
  labels:
    app.kubernetes.io/name: my-new-service
EOF
```

#### Step 2: Create ConfigMap

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-new-service-config
  namespace: my-new-service
data:
  APP_PORT: "5000"
  LOG_LEVEL: "info"
  DATABASE_URL: "postgresql://user:pass@db-host:5432/mydb"
EOF
```

#### Step 3: Create Deployment

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-new-service
  namespace: my-new-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: my-new-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: my-new-service
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "5000"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: app
          image: python:3.12-slim          # ← Replace with YOUR image
          command: ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5000"]
          ports:
            - name: http
              containerPort: 5000
          envFrom:
            - configMapRef:
                name: my-new-service-config
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 5
EOF
```

#### Step 4: Create Service

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: my-new-service
  namespace: my-new-service
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: my-new-service
  ports:
    - name: http
      port: 80
      targetPort: http
EOF
```

#### Step 5: Create Ingress (optional — for external access)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-new-service-ingress
  namespace: my-new-service
spec:
  ingressClassName: nginx
  rules:
    - host: my-new-service.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-new-service
                port:
                  name: http
EOF

# Add to /etc/hosts:
echo "127.0.0.1 my-new-service.local" | sudo tee -a /etc/hosts
```

#### Step 6: Add HPA

```bash
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-new-service-hpa
  namespace: my-new-service
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-new-service
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
EOF
```

#### Verify New Service

```bash
kubectl get all -n my-new-service
kubectl port-forward -n my-new-service svc/my-new-service 5000:80
curl http://localhost:5000/health
```

---

## Checklist: Deploying Any New Service

- [ ] Create Namespace
- [ ] Create ConfigMap (non-sensitive config)
- [ ] Create Secret (passwords, API keys) — if needed
- [ ] Create Deployment (image, ports, probes, resources)
- [ ] Create Service (internal load balancer)
- [ ] Create Ingress (external access) — if needed
- [ ] Create HPA (autoscaling) — if needed
- [ ] Create PDB (disruption budget) — if critical
- [ ] Add ServiceMonitor (Prometheus scraping) — if metrics exposed
- [ ] Verify: pods running, probes passing, traffic flowing

---

## Teardown

```bash
# Delete just one service
kubectl delete namespace my-new-service

# Delete everything (entire cluster)
./bootstrap.sh --destroy
```
