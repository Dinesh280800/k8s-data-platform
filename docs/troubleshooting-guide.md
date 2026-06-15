# Troubleshooting Guide

This guide is symptom-first: find the issue, run the checks, apply the fix.

## 1. Frontend or query URL does not open

Symptoms:

- `http://frontend.local` fails
- `http://query.local` fails
- `curl` shows connection reset

Checks:

```bash
grep -n 'frontend.local\|query.local' /etc/hosts
kubectl get ingress -A
kubectl get pods -n ingress-nginx -o wide
podman port data-platform-cluster-control-plane
```

Likely cause:

- Ingress controller scheduled on worker node, but kind host ports 80/443 are mapped on control-plane.

Fix:

```bash
kubectl -n ingress-nginx patch deployment ingress-nginx-controller \
  --type='merge' \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/hostname":"data-platform-cluster-control-plane"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
kubectl -n ingress-nginx rollout restart deployment ingress-nginx-controller
kubectl -n ingress-nginx rollout status deployment ingress-nginx-controller --timeout=180s
```

## 2. Pods stuck in `ContainerCreating`

Symptoms:

- app or Trino pods stay in `ContainerCreating` for long time

Checks:

```bash
kubectl get pods -A
kubectl describe pod -n data-platform <pod-name>
kubectl describe pod -n analytics <pod-name>
```

Likely causes:

- First-time image pull delay
- custom images not loaded into kind

Fix for custom images:

```bash
for img in api-discovery api-validator api-enricher query-router; do
  podman save data-platform/${img}:local -o /tmp/${img}.tar
  KIND_EXPERIMENTAL_PROVIDER=podman kind load image-archive /tmp/${img}.tar --name data-platform-cluster
  rm -f /tmp/${img}.tar
done
kubectl rollout restart deployment -n data-platform api-discovery api-validator api-enricher query-router
```

## 3. Podman + kind load fails with Docker daemon error

Symptoms:

- `kind load ...` fails with `Cannot connect to Docker daemon`

Cause:

- `kind` defaults to Docker unless provider is set.

Fix:

```bash
KIND_EXPERIMENTAL_PROVIDER=podman kind load image-archive /tmp/query-router.tar --name data-platform-cluster
```

## 4. Trino query fails: `NO_NODES_AVAILABLE`

Symptoms:

- query-router returns error with `errorName: NO_NODES_AVAILABLE`
- Trino UI shows internal error for the same query

Checks:

```bash
kubectl get pods -n analytics -o wide
kubectl exec -n analytics deployment/trino-coordinator -- sh -lc "curl -sS -H 'X-Trino-User: platform' http://localhost:8080/v1/node"
kubectl logs -n analytics deployment/trino-workers --tail=150
```

Likely causes:

- Worker not registered yet
- Worker missing connector catalog config

Fix:

```bash
kubectl apply -f platform/query/trino.yaml
kubectl rollout restart deployment/trino-workers -n analytics
kubectl rollout status deployment/trino-workers -n analytics --timeout=240s
```

## 5. Trino query succeeds but returns zero rows

Symptoms:

- `status: ok` with empty `rows`

Cause:

- Table is empty.

Fix (seed data):

```bash
POSTGRES_POD=$(kubectl get pod -n store -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n store "$POSTGRES_POD" -- sh -lc "psql -U platform -d apis <<'SQL'
INSERT INTO catalog.apis (name, base_url, source) VALUES
('jsonplaceholder-posts','https://jsonplaceholder.typicode.com/posts','jsonplaceholder'),
('jsonplaceholder-users','https://jsonplaceholder.typicode.com/users','jsonplaceholder'),
('openlibrary-search','https://openlibrary.org/search.json','openlibrary')
ON CONFLICT DO NOTHING;
SQL"
```

## 6. RabbitMQ shows no queues

Symptoms:

- RabbitMQ UI `Queues and Streams` shows zero queues
- KEDA logs contain queue not found warnings

Fix:

```bash
bash test/create-queues.sh
```

Or via API:

```bash
for q in api-discovery-jobs api-validator-jobs api-enrichment-jobs; do
  curl -sS -u guest:guest -X PUT http://localhost:15672/api/queues/%2F/$q \
    -H 'Content-Type: application/json' -d '{"durable":true}'
done
```

## 7. KEDA does not scale up

Symptoms:

- queue depth increases, replicas stay at 1

Checks:

```bash
kubectl get scaledobject -n data-platform
kubectl describe scaledobject -n data-platform api-discovery-scaledobject
kubectl logs -n keda deploy/keda-operator --tail=150
curl -sS -u guest:guest http://localhost:15672/api/queues/%2F | python3 -c "import sys,json; [print(q['name'], q.get('messages_ready',0)) for q in json.load(sys.stdin)]"
```

Common causes:

- queue name mismatch
- queue missing
- queue depth below threshold 10

Fix:

```bash
python3 test/keda_scale_test.py --queue api-discovery-jobs --count 50 --watch 200
```

## 8. Prometheus not opening without port-forward

Symptoms:

- `localhost:9090` works only while port-forward runs

Cause:

- Prometheus service is ClusterIP by default.

Fix:

```bash
kubectl apply -f monitoring/ingress.yaml
sudo bash -c 'grep -q prometheus.local /etc/hosts || echo "127.0.0.1 prometheus.local alertmanager.local" >> /etc/hosts'
```

Use:

- `http://prometheus.local`
- `http://alertmanager.local`

## 9. Metrics API errors in HPA/KEDA events

Symptoms:

- `FailedGetResourceMetric` for cpu/memory

Checks:

```bash
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
kubectl top pods -A
```

Fix:

```bash
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
```

## 10. Useful quick-debug commands

Cluster wide non-running pods:

```bash
kubectl get pods -A | awk 'NR==1 || $4!="Running" && $4!="Completed"'
```

Recent events:

```bash
kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -n 80
```

Query-router test:

```bash
curl -sS -X POST http://query.local/query \
  -H 'Content-Type: application/json' \
  -d '{"query":"SHOW TABLES FROM postgresql.catalog","maxRows":50}'
```

Ingress check:

```bash
kubectl get ingress -A
kubectl get pods -n ingress-nginx -o wide
```
