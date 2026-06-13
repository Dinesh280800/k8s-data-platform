# GitHub Repository & CI/CD Guide

## Part 1: Push to GitHub

### Prerequisites

- GitHub account: [github.com/Dinesh280800](https://github.com/Dinesh280800)
- Git installed: `git --version`
- GitHub CLI (optional): `brew install gh`

### Option A: Using GitHub CLI (Easiest)

```bash
cd /Users/ds/Downloads/Learnings/k8s-kind-project

# Initialize git repository
git init
git add .
git commit -m "feat: initial Kubernetes Kind cluster project

- Kind multi-node cluster config (1 CP + 2 workers)
- Core app: Deployment, Service, Ingress, HPA, PDB
- Monitoring: Prometheus, Grafana, Alertmanager, Loki
- KEDA event-driven autoscaling
- Bootstrap script and verification tests
- Comprehensive documentation"

# Create repo and push (interactive)
gh repo create k8s-kind-project --public --source=. --push
```

### Option B: Manual GitHub + Git

#### Step 1: Create repo on GitHub

1. Go to https://github.com/new
2. Repository name: `k8s-kind-project`
3. Description: "Production-grade Kubernetes deployment on local Kind cluster with monitoring, autoscaling, and observability"
4. Public or Private: your choice
5. **DO NOT** initialize with README (we already have one)
6. Click "Create repository"

#### Step 2: Push local project

```bash
cd /Users/ds/Downloads/Learnings/k8s-kind-project

# Initialize
git init
git branch -M main

# Create .gitignore
cat > .gitignore << 'EOF'
# Kubernetes
*.kubeconfig
kubeconfig

# Secrets (never commit real secrets)
**/secret-values.yaml
**/secrets-prod.yaml

# OS files
.DS_Store
Thumbs.db

# IDE
.vscode/
.idea/

# Helm
charts/
*.tgz

# Temporary
tmp/
*.log
EOF

# Stage and commit
git add .
git commit -m "feat: initial Kubernetes Kind cluster project"

# Add remote and push
git remote add origin https://github.com/Dinesh280800/k8s-kind-project.git
git push -u origin main
```

---

## Part 2: Branch Strategy

### Recommended: GitHub Flow (Simple)

```
main (protected) ← always deployable
  │
  ├── feature/add-redis-service     ← work branch
  ├── feature/add-prometheus-alerts ← work branch
  └── fix/grafana-datasource        ← fix branch
```

**Workflow:**
```bash
# Create a feature branch
git checkout -b feature/add-redis-service

# Make changes, commit
git add .
git commit -m "feat: add Redis deployment for caching"

# Push and create PR
git push -u origin feature/add-redis-service
gh pr create --title "Add Redis service" --body "Adds Redis deployment for session caching"

# After review, merge on GitHub (squash merge recommended)
# Then locally:
git checkout main
git pull
git branch -d feature/add-redis-service
```

### Protect Main Branch

```bash
# Using GitHub CLI:
gh repo edit --default-branch main
gh api repos/Dinesh280800/k8s-kind-project/branches/main/protection \
  --method PUT \
  --field required_pull_request_reviews='{"required_approving_review_count":1}' \
  --field enforce_admins=false
```

Or via GitHub UI: **Settings → Branches → Add rule → Branch name pattern: `main`**
- ✅ Require pull request reviews
- ✅ Require status checks to pass

---

## Part 3: Commit Message Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add new feature
fix: bug fix
docs: documentation changes
chore: maintenance (no code change)
refactor: code restructuring
test: add/update tests
```

Examples:
```bash
git commit -m "feat: add Redis deployment with persistence"
git commit -m "fix: correct Grafana datasource conflict"
git commit -m "docs: add dashboard creation guide"
git commit -m "chore: update Helm chart versions"
```

---

## Part 4: CI/CD with GitHub Actions

Create `.github/workflows/validate.yaml`:

```bash
mkdir -p .github/workflows
```

```yaml
# .github/workflows/validate.yaml
name: Validate Kubernetes Manifests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install kubeval
        run: |
          wget https://github.com/instrumenta/kubeval/releases/latest/download/kubeval-linux-amd64.tar.gz
          tar xf kubeval-linux-amd64.tar.gz
          sudo mv kubeval /usr/local/bin/

      - name: Validate YAML manifests
        run: |
          find app/ -name '*.yaml' -exec kubeval --strict {} \;

      - name: Lint with kube-linter
        uses: stackrox/kube-linter-action@v1
        with:
          directory: app/

  helm-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Helm
        uses: azure/setup-helm@v3

      - name: Lint Helm values
        run: |
          helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
          helm repo add grafana https://grafana.github.io/helm-charts
          helm repo update
          helm template monitoring prometheus-community/kube-prometheus-stack \
            --values monitoring/prometheus/values.yaml > /dev/null
          echo "✓ Prometheus values are valid"

  integration-test:
    runs-on: ubuntu-latest
    needs: [validate, helm-lint]
    if: github.event_name == 'push'
    steps:
      - uses: actions/checkout@v4

      - name: Create Kind cluster
        uses: helm/kind-action@v1
        with:
          config: kind/cluster-config.yaml
          cluster_name: test-cluster

      - name: Deploy application
        run: |
          kubectl apply -f app/namespace.yaml
          kubectl apply -f app/configmap.yaml
          kubectl apply -f app/secret.yaml
          kubectl apply -f app/deployment.yaml
          kubectl apply -f app/service.yaml

      - name: Wait for deployment
        run: |
          kubectl rollout status deployment/complex-app -n complex-app --timeout=120s

      - name: Verify pods are ready
        run: |
          READY=$(kubectl get pods -n complex-app -l app.kubernetes.io/name=complex-app \
            -o jsonpath='{.items[*].status.containerStatuses[0].ready}')
          echo "Pod readiness: $READY"
          [[ "$READY" == *"true"* ]] || exit 1
```

### Push the workflow:

```bash
git add .github/
git commit -m "ci: add GitHub Actions for YAML validation and integration tests"
git push
```

---

## Part 5: Versioning Strategy

### Semantic Versioning for the Project

```
v1.0.0 → Initial release (cluster + app + monitoring)
v1.1.0 → Added KEDA autoscaling
v1.2.0 → Added Loki logging
v2.0.0 → Breaking change (e.g., different cluster topology)
```

### Create Tags/Releases

```bash
# Tag a release
git tag -a v1.0.0 -m "Initial release: Kind cluster with full observability stack"
git push origin v1.0.0

# Create GitHub release (with release notes)
gh release create v1.0.0 --title "v1.0.0 - Initial Release" --notes "
## What's included
- Kind multi-node cluster (1 CP + 2 workers)
- Core application with production-grade deployment patterns
- Prometheus + Grafana + Alertmanager monitoring
- Loki + Promtail log aggregation  
- KEDA event-driven autoscaling
- Comprehensive documentation and verification scripts
"
```

---

## Part 6: Repository Structure (Final)

```
k8s-kind-project/
├── .github/
│   └── workflows/
│       └── validate.yaml           # CI/CD pipeline
├── .gitignore
├── README.md                       # Project overview & quick start
├── bootstrap.sh                    # One-command setup
├── kind/
│   └── cluster-config.yaml
├── app/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   └── pdb.yaml
├── monitoring/
│   ├── namespace.yaml
│   ├── service-monitor.yaml
│   ├── prometheus/
│   │   ├── values.yaml
│   │   └── alert-rules.yaml
│   └── loki/
│       └── values.yaml
├── keda/
│   └── scaled-object.yaml
├── verification/
│   ├── verify.sh
│   └── test-scaling.sh
└── docs/
    ├── 01-architecture-and-yaml-guide.md
    ├── 02-deployment-guide.md
    ├── 03-dashboard-guide.md
    └── 04-github-and-cicd.md       # This file
```

---

## Quick Reference Commands

```bash
# Status
git status
git log --oneline -10

# Branching
git checkout -b feature/my-feature
git push -u origin feature/my-feature

# Sync with remote
git fetch origin
git pull origin main

# Undo last commit (keep changes)
git reset --soft HEAD~1

# View diff before committing
git diff --staged
```
