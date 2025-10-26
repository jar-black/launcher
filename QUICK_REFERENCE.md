# Quick Reference Guide

## Common Commands

### Deployment

```bash
# Deploy to dev
./deploy.sh dev

# Deploy with dry-run
./deploy.sh dev --dry-run

# Show differences
./deploy.sh dev --diff

# Rollback
./deploy.sh dev --rollback

# Deploy to production (requires confirmation)
./deploy.sh prod
```

### Secret Management

```bash
# Initialize secrets for environment
./scripts/manage-secrets.sh init dev

# Validate secrets
./scripts/manage-secrets.sh validate dev

# View current secrets
./scripts/manage-secrets.sh view dev

# Rotate a secret
./scripts/manage-secrets.sh rotate prod db.password
```

### Kubernetes Operations

```bash
# Get pods
kubectl get pods -n dev

# View logs
kubectl logs -n dev -l app=app -f

# Describe pod
kubectl describe pod <pod-name> -n dev

# Get all resources
kubectl get all -n dev

# Port forward
kubectl port-forward -n dev service/dev-app 8080:8080

# Execute command in pod
kubectl exec -it <pod-name> -n dev -- /bin/sh

# View deployment status
kubectl rollout status deployment/dev-app -n dev

# View rollout history
kubectl rollout history deployment/dev-app -n dev

# Scale deployment
kubectl scale deployment/dev-app --replicas=3 -n dev
```

### Docker Operations

```bash
# Build image
docker build -t your-registry/app:v1.0.0 .

# Tag image
docker tag your-registry/app:v1.0.0 your-registry/app:dev-latest

# Push image
docker push your-registry/app:v1.0.0

# Pull image
docker pull your-registry/app:v1.0.0

# Login to registry
docker login your-registry.io
```

### Kustomize

```bash
# View generated manifests
kubectl kustomize k8s/overlays/dev

# Save to file
kubectl kustomize k8s/overlays/dev > manifests.yaml

# Validate
kubectl kustomize k8s/overlays/dev | kubectl apply --dry-run=client -f -

# Apply directly
kubectl apply -k k8s/overlays/dev
```

## Directory Structure

```
launcher/
├── deploy.sh                 # Main deployment script
├── k8s/
│   ├── base/                 # Base manifests
│   └── overlays/
│       ├── dev/              # Dev environment
│       ├── stage/            # Staging environment
│       └── prod/             # Production environment
├── scripts/
│   └── manage-secrets.sh     # Secret management
└── docs/
    ├── README.md             # Main documentation
    └── DEPLOYMENT_GUIDE.md   # Deployment guide
```

## Environment Namespaces

- **dev** → `dev` namespace
- **stage** → `stage` namespace
- **prod** → `production` namespace

## Important Files

### Per Environment

| File | Purpose |
|------|---------|
| `kustomization.yaml` | Environment configuration |
| `secrets.env` | Secrets (DO NOT COMMIT) |

### Base Configuration

| File | Purpose |
|------|---------|
| `deployment.yaml` | Pod and container spec |
| `service.yaml` | Service definition |
| `configmap.yaml` | Application config |
| `secret.yaml` | Secret template |
| `ingress.yaml` | Ingress configuration |
| `postgres-external.yaml` | External Postgres service |

## Health Check Endpoints

Your app must implement:

- `GET /health/live` on port 8081 - Liveness probe
- `GET /health/ready` on port 8081 - Readiness probe

## Environment Variables

Your app receives these environment variables:

```bash
# From ConfigMap
APP_ENV=development|staging|production
DB_HOST=postgres-external
DB_PORT=5432
DB_NAME=app_db

# From Secrets
DB_USER=<from secrets.env>
DB_PASSWORD=<from secrets.env>
API_KEY=<from secrets.env>
```

## Troubleshooting

### Pod won't start

```bash
# Check pod status
kubectl describe pod <pod-name> -n dev

# Check logs
kubectl logs <pod-name> -n dev

# Check events
kubectl get events -n dev --sort-by='.lastTimestamp'
```

### Image pull issues

```bash
# Verify image exists
docker pull your-registry/app:tag

# Check image pull secret
kubectl get secret registry-credentials -n dev

# Create image pull secret
kubectl create secret docker-registry registry-credentials \
  --docker-server=your-registry \
  --docker-username=user \
  --docker-password=pass \
  -n dev
```

### Database connection issues

```bash
# Test DNS
kubectl run -it --rm debug --image=busybox -n dev -- nslookup postgres-external

# Test connection
kubectl run -it --rm debug --image=postgres:15 -n dev -- \
  psql -h postgres-external -U user -d db
```

### Health checks failing

```bash
# Check health endpoint manually
kubectl port-forward <pod-name> 8081:8081 -n dev
curl http://localhost:8081/health/live
curl http://localhost:8081/health/ready

# Adjust probe settings in deployment.yaml
initialDelaySeconds: 60  # Increase if app takes long to start
periodSeconds: 10        # How often to check
failureThreshold: 3      # How many failures before restart
```

## Production Checklist

Before deploying to production:

- [ ] Secrets file has no placeholders
- [ ] Image tag is specific version (not :latest)
- [ ] Database migrations are applied
- [ ] Health checks are working
- [ ] Resource limits are appropriate
- [ ] Ingress/DNS is configured
- [ ] TLS certificates are ready
- [ ] Monitoring is configured
- [ ] Tested in staging environment
- [ ] Rollback procedure is documented

## Resource Limits

### Development
```yaml
requests:
  memory: "128Mi"
  cpu: "100m"
limits:
  memory: "256Mi"
  cpu: "500m"
```

### Production
```yaml
requests:
  memory: "512Mi"
  cpu: "200m"
limits:
  memory: "1Gi"
  cpu: "1000m"
```

## Scaling

```bash
# Manual scaling
kubectl scale deployment/<name> --replicas=5 -n <namespace>

# Check HPA (if configured)
kubectl get hpa -n <namespace>

# Set up HPA
kubectl autoscale deployment/<name> \
  --cpu-percent=70 \
  --min=2 \
  --max=10 \
  -n <namespace>
```

## Logs

```bash
# Stream logs
kubectl logs -f <pod-name> -n <namespace>

# Last 100 lines
kubectl logs --tail=100 <pod-name> -n <namespace>

# Previous pod instance
kubectl logs --previous <pod-name> -n <namespace>

# All pods with label
kubectl logs -l app=app -n <namespace> --tail=50 -f

# Logs since timestamp
kubectl logs --since=1h <pod-name> -n <namespace>
```

## Monitoring

```bash
# Resource usage
kubectl top pods -n <namespace>
kubectl top nodes

# Watch resources
watch kubectl get pods -n <namespace>

# Port forward to app
kubectl port-forward svc/<service-name> 8080:8080 -n <namespace>
```

## Quick Fixes

### Restart all pods
```bash
kubectl rollout restart deployment/<name> -n <namespace>
```

### Delete failed pod
```bash
kubectl delete pod <pod-name> -n <namespace>
```

### Update secret
```bash
# Edit secrets.env
./scripts/manage-secrets.sh update <env>
# Restart pods to pick up new secrets
kubectl rollout restart deployment/<name> -n <namespace>
```

### Force pull new image
```bash
# Update image tag in kustomization.yaml
# Then deploy
./deploy.sh <env>
```
