# Kubernetes Deployment Launcher

A production-ready Kubernetes deployment system for Scala microservices using Kustomize.

## Features

- **Multi-environment support**: dev, stage, prod
- **Kustomize-based configuration**: No templating, pure Kubernetes manifests
- **Secret management**: Simple and secure secret handling
- **Deployment validation**: Pre-deployment checks and dry-runs
- **Safety features**: Production confirmations, rollback support, image tag validation
- **External service support**: Pre-configured for external Postgres database
- **Rolling updates**: Zero-downtime deployments with health checks

## Directory Structure

```
.
├── deploy.sh                    # Main deployment script
├── k8s/
│   ├── base/                    # Base Kubernetes manifests
│   │   ├── deployment.yaml      # Application deployment
│   │   ├── service.yaml         # Service definition
│   │   ├── configmap.yaml       # Configuration
│   │   ├── secret.yaml          # Secret template
│   │   ├── ingress.yaml         # Ingress configuration
│   │   ├── postgres-external.yaml  # External Postgres service
│   │   └── kustomization.yaml   # Base kustomization
│   ├── overlays/
│   │   ├── dev/                 # Development overlay
│   │   ├── stage/               # Staging overlay
│   │   └── prod/                # Production overlay
│   └── secrets/
│       └── secrets.env.example  # Secret template
├── scripts/
│   └── manage-secrets.sh        # Secret management utility
└── README.md
```

## Quick Start

### Prerequisites

- `kubectl` installed and configured
- Access to a Kubernetes cluster
- Docker registry with your Scala application images

### 1. Initial Setup

```bash
# Clone the repository
git clone <your-repo>
cd launcher

# Make scripts executable
chmod +x deploy.sh
chmod +x scripts/manage-secrets.sh
```

### 2. Configure Secrets

Create secrets for each environment:

```bash
# Initialize secrets for dev
./scripts/manage-secrets.sh init dev

# Edit the secrets file
nano k8s/overlays/dev/secrets.env

# Repeat for stage and prod
./scripts/manage-secrets.sh init stage
./scripts/manage-secrets.sh init prod
```

### 3. Customize Configuration

Edit the overlay files for your application:

**Dev environment** (`k8s/overlays/dev/kustomization.yaml`):
```yaml
images:
- name: your-registry/your-app
  newName: your-registry/scala-app  # Your actual registry
  newTag: dev-latest
```

**Stage environment** (`k8s/overlays/stage/kustomization.yaml`):
```yaml
images:
- name: your-registry/your-app
  newName: your-registry/scala-app
  newTag: stage-v1.2.3  # Specific version
```

**Prod environment** (`k8s/overlays/prod/kustomization.yaml`):
```yaml
images:
- name: your-registry/your-app
  newName: your-registry/scala-app
  newTag: v1.2.3  # Never use :latest in prod!
```

### 4. Configure External Postgres

Update the Postgres connection in base configuration:

Edit `k8s/base/postgres-external.yaml`:
```yaml
spec:
  externalName: postgres.your-network.local  # Your Postgres hostname
```

Or use IP-based connection (uncomment the Endpoints section in the file).

Update database configuration in each overlay's `secrets.env`:
```bash
db.user=your_db_user
db.password=your_secure_password
```

### 5. Deploy

```bash
# Deploy to dev (with dry-run first)
./deploy.sh dev --dry-run
./deploy.sh dev

# Deploy to stage
./deploy.sh stage --diff  # Show changes first
./deploy.sh stage

# Deploy to prod (requires confirmation)
./deploy.sh prod
```

## Usage

### Deployment Script

```bash
./deploy.sh <environment> [options]
```

**Options:**
- `--dry-run`: Validate without applying changes
- `--diff`: Show what will change
- `--rollback`: Rollback to previous version
- `--skip-validation`: Skip pre-deployment checks

**Examples:**
```bash
# Deploy to development
./deploy.sh dev

# Validate production deployment
./deploy.sh prod --dry-run

# Show differences before deploying
./deploy.sh stage --diff

# Rollback production
./deploy.sh prod --rollback
```

### Secret Management

```bash
./scripts/manage-secrets.sh <command> <environment>
```

**Commands:**
- `init <env>`: Create secrets file for environment
- `validate <env>`: Validate secrets format
- `create <env>`: Create secrets in cluster
- `update <env>`: Update existing secrets
- `view <env>`: View current secrets (decoded)
- `rotate <env> <key>`: Rotate a specific secret

**Examples:**
```bash
# Initialize secrets for dev
./scripts/manage-secrets.sh init dev

# Validate production secrets
./scripts/manage-secrets.sh validate prod

# View current dev secrets
./scripts/manage-secrets.sh view dev

# Rotate database password in prod
./scripts/manage-secrets.sh rotate prod db.password
```

## Configuration

### Environment-Specific Settings

Each environment overlay can customize:

- **Replicas**: Number of pod replicas
- **Resources**: CPU and memory limits
- **Image tags**: Docker image versions
- **ConfigMaps**: Application configuration
- **Secrets**: Sensitive data
- **Ingress**: Domain names and TLS

### ConfigMap Values

Common configuration in `k8s/base/configmap.yaml`:
```yaml
data:
  environment: "development"
  log.level: "INFO"
  db.host: "postgres-external"
  db.port: "5432"
  db.name: "app_db"
  db.pool.size: "10"
```

Override in overlays using:
```yaml
configMapGenerator:
- name: app-config
  behavior: merge
  literals:
  - environment=production
  - log.level=WARN
```

### Resource Limits

Default limits (base):
```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

Production typically needs more:
```yaml
resources:
  requests:
    memory: "512Mi"
    cpu: "200m"
  limits:
    memory: "1Gi"
    cpu: "1000m"
```

## Health Checks

The deployment includes:

- **Liveness probe**: Checks if the app is running (port 8081)
  - Path: `/health/live`
  - Initial delay: 60s
  - Period: 10s

- **Readiness probe**: Checks if app can receive traffic
  - Path: `/health/ready`
  - Initial delay: 30s
  - Period: 5s

Make sure your Scala application implements these endpoints:

```scala
// Example using http4s
val healthRoutes = HttpRoutes.of[F] {
  case GET -> Root / "health" / "live" =>
    Ok("alive")

  case GET -> Root / "health" / "ready" =>
    // Check database connection, etc.
    if (isReady) Ok("ready") else ServiceUnavailable("not ready")
}
```

## External Services

### Postgres Configuration

The setup includes two options for external Postgres:

**Option 1: DNS-based (default)**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-external
spec:
  type: ExternalName
  externalName: postgres.your-network.local
```

**Option 2: IP-based**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-external
spec:
  type: ClusterIP
  clusterIP: None
---
apiVersion: v1
kind: Endpoints
metadata:
  name: postgres-external
subsets:
- addresses:
  - ip: 192.168.1.100  # Your Postgres IP
  ports:
  - port: 5432
```

Access from your application using:
```
jdbc:postgresql://postgres-external:5432/dbname
```

## Advanced Features

### Custom Namespaces

Each environment uses its own namespace:
- Dev: `dev`
- Stage: `stage`
- Prod: `production`

Create namespaces:
```bash
kubectl create namespace dev
kubectl create namespace stage
kubectl create namespace production
```

### Image Pull Secrets

If using private Docker registry:

```bash
kubectl create secret docker-registry registry-credentials \
  --docker-server=your-registry.io \
  --docker-username=your-username \
  --docker-password=your-password \
  --docker-email=your-email \
  -n <namespace>
```

### Rolling Updates

Configured for zero-downtime deployments:
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1        # Max pods above desired count
    maxUnavailable: 0  # Always keep all pods running
```

### Ingress and TLS

Configure ingress in each overlay:

```yaml
patches:
- target:
    kind: Ingress
    name: app
  patch: |-
    - op: replace
      path: /spec/rules/0/host
      value: your-domain.com
```

For TLS, ensure cert-manager is installed:
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

## Production Checklist

Before deploying to production:

- [ ] Secrets use strong, unique passwords (no placeholders)
- [ ] Image tags use specific versions (not `:latest`)
- [ ] Resource limits are appropriate for load
- [ ] Health check endpoints are implemented
- [ ] Database connection is tested
- [ ] Ingress/DNS is configured correctly
- [ ] TLS certificates are set up
- [ ] Monitoring and logging are configured
- [ ] Backup strategy is in place
- [ ] Rollback procedure is tested

## Troubleshooting

### View pod logs
```bash
kubectl logs -n <namespace> -l app=app --tail=100 -f
```

### Check pod status
```bash
kubectl get pods -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
```

### Debug deployment
```bash
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

### Test connectivity to Postgres
```bash
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql -h postgres-external -U your_user -d your_db
```

### Rollback deployment
```bash
./deploy.sh <env> --rollback

# Or manually
kubectl rollout undo deployment/<deployment-name> -n <namespace>
```

### View generated manifests
```bash
kubectl kustomize k8s/overlays/dev > dev-manifest.yaml
```

## Security Best Practices

1. **Never commit secrets**: Always use `.gitignore` for `secrets.env` files
2. **Use specific image tags**: Never use `:latest` in production
3. **Limit resources**: Prevent resource exhaustion with limits
4. **Run as non-root**: Security context enforces non-root user
5. **Use secrets for sensitive data**: Not ConfigMaps
6. **Enable RBAC**: Use Kubernetes RBAC for access control
7. **Network policies**: Restrict pod-to-pod communication
8. **Consider secret management tools**: Sealed Secrets, External Secrets Operator, or Vault

### Recommended: Sealed Secrets (for production)

For better secret management in Git:

```bash
# Install sealed-secrets
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Install kubeseal
brew install kubeseal  # or download binary

# Create sealed secret
kubectl create secret generic app-secrets \
  --from-env-file=secrets.env \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > sealed-secret.yaml

# Commit sealed-secret.yaml to Git (safe!)
```

## Contributing

1. Create feature branch
2. Test changes in dev environment
3. Update documentation
4. Submit pull request

## License

See LICENSE file.

## Support

For issues or questions, please open an issue in the repository.
