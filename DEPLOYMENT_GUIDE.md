# Deployment Guide for Scala Microservices

## Overview

This guide covers deploying Scala-based microservices to Kubernetes using our deployment system.

## Prerequisites

### 1. Docker Image

Your Scala application should be containerized. Example Dockerfile:

```dockerfile
FROM eclipse-temurin:17-jre-alpine

# Add non-root user
RUN addgroup -g 1000 appuser && \
    adduser -u 1000 -G appuser -s /bin/sh -D appuser

WORKDIR /app

# Copy your Scala application JAR
COPY target/scala-2.13/your-app.jar /app/app.jar

# Change ownership
RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 8080 8081

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

### 2. Health Check Endpoints

Your Scala app must expose health check endpoints on port 8081:

- `/health/live` - Liveness check
- `/health/ready` - Readiness check

#### Example with Akka HTTP:

```scala
import akka.http.scaladsl.server.Directives._
import akka.http.scaladsl.server.Route

val healthRoutes: Route =
  pathPrefix("health") {
    path("live") {
      get {
        complete("OK")
      }
    } ~
    path("ready") {
      get {
        // Check if database is accessible, etc.
        if (isApplicationReady()) {
          complete("Ready")
        } else {
          complete(StatusCodes.ServiceUnavailable, "Not Ready")
        }
      }
    }
  }
```

#### Example with Play Framework:

```scala
// conf/routes
GET     /health/live      controllers.HealthController.liveness
GET     /health/ready     controllers.HealthController.readiness

// app/controllers/HealthController.scala
class HealthController @Inject()(
  cc: ControllerComponents,
  dbService: DatabaseService
) extends AbstractController(cc) {

  def liveness = Action {
    Ok("alive")
  }

  def readiness = Action.async {
    dbService.checkConnection().map { isConnected =>
      if (isConnected) Ok("ready")
      else ServiceUnavailable("not ready")
    }
  }
}
```

#### Example with http4s:

```scala
import cats.effect._
import org.http4s._
import org.http4s.dsl.io._

val healthRoutes = HttpRoutes.of[IO] {
  case GET -> Root / "health" / "live" =>
    Ok("alive")

  case GET -> Root / "health" / "ready" =>
    // Check dependencies
    for {
      dbReady <- checkDatabase()
      result <- if (dbReady) Ok("ready")
                else ServiceUnavailable("not ready")
    } yield result
}
```

### 3. Configuration

Your Scala app should read configuration from environment variables:

```scala
// application.conf (with environment variable overrides)
app {
  environment = ${APP_ENV}
  port = ${APP_PORT}

  database {
    host = ${DB_HOST}
    port = ${DB_PORT}
    name = ${DB_NAME}
    user = ${DB_USER}
    password = ${DB_PASSWORD}
    pool-size = ${?DB_POOL_SIZE}
  }
}
```

## Step-by-Step Deployment

### Step 1: Build and Push Docker Image

```bash
# Build your Scala application
sbt clean compile test package

# Build Docker image
docker build -t your-registry/scala-app:v1.0.0 .

# Push to registry
docker push your-registry/scala-app:v1.0.0

# Tag for environment
docker tag your-registry/scala-app:v1.0.0 your-registry/scala-app:dev-latest
docker push your-registry/scala-app:dev-latest
```

### Step 2: Configure Deployment

Update `k8s/overlays/dev/kustomization.yaml`:

```yaml
images:
- name: your-registry/your-app
  newName: your-registry/scala-app
  newTag: dev-latest
```

### Step 3: Configure Database Connection

Update `k8s/base/postgres-external.yaml` with your Postgres server:

```yaml
spec:
  externalName: postgres.your-company.local
```

### Step 4: Set Up Secrets

```bash
# Initialize secrets
./scripts/manage-secrets.sh init dev

# Edit secrets file
nano k8s/overlays/dev/secrets.env
```

Add your database credentials:
```bash
db.user=myapp_user
db.password=secure_password_here
```

### Step 5: Validate Configuration

```bash
# Validate secrets
./scripts/manage-secrets.sh validate dev

# Test dry-run
./deploy.sh dev --dry-run

# View generated manifests
kubectl kustomize k8s/overlays/dev > /tmp/dev-manifests.yaml
cat /tmp/dev-manifests.yaml
```

### Step 6: Deploy to Dev

```bash
# Deploy
./deploy.sh dev

# Watch rollout
kubectl rollout status deployment/dev-app -n dev

# Check pods
kubectl get pods -n dev

# View logs
kubectl logs -n dev -l app=app --tail=50 -f
```

### Step 7: Test Application

```bash
# Port forward to test locally
kubectl port-forward -n dev service/dev-app 8080:8080

# Test in another terminal
curl http://localhost:8080/
curl http://localhost:8081/health/live
curl http://localhost:8081/health/ready

# Or test via ingress (if configured)
curl https://dev.app.example.com
```

### Step 8: Deploy to Staging

```bash
# Build and tag for staging
docker tag your-registry/scala-app:v1.0.0 your-registry/scala-app:stage-v1.0.0
docker push your-registry/scala-app:stage-v1.0.0

# Update staging overlay
# Edit k8s/overlays/stage/kustomization.yaml
images:
- name: your-registry/your-app
  newName: your-registry/scala-app
  newTag: stage-v1.0.0

# Set up staging secrets
./scripts/manage-secrets.sh init stage
# Edit k8s/overlays/stage/secrets.env with staging credentials

# Deploy
./deploy.sh stage --dry-run
./deploy.sh stage
```

### Step 9: Deploy to Production

```bash
# Tag production image (use specific version, NEVER :latest)
docker tag your-registry/scala-app:v1.0.0 your-registry/scala-app:v1.0.0
docker push your-registry/scala-app:v1.0.0

# Update production overlay
# Edit k8s/overlays/prod/kustomization.yaml
images:
- name: your-registry/your-app
  newName: your-registry/scala-app
  newTag: v1.0.0  # Specific version!

# Set up production secrets (CRITICAL: use strong passwords!)
./scripts/manage-secrets.sh init prod
# Edit k8s/overlays/prod/secrets.env

# Validate
./scripts/manage-secrets.sh validate prod
./deploy.sh prod --dry-run

# Review changes
./deploy.sh prod --diff

# Deploy (requires confirmation)
./deploy.sh prod
```

## Database Setup

### Create Database User

On your Postgres server:

```sql
-- Development
CREATE USER myapp_dev_user WITH PASSWORD 'dev_password';
CREATE DATABASE myapp_dev OWNER myapp_dev_user;
GRANT ALL PRIVILEGES ON DATABASE myapp_dev TO myapp_dev_user;

-- Staging
CREATE USER myapp_stage_user WITH PASSWORD 'stage_password';
CREATE DATABASE myapp_stage OWNER myapp_stage_user;
GRANT ALL PRIVILEGES ON DATABASE myapp_stage TO myapp_stage_user;

-- Production
CREATE USER myapp_prod_user WITH PASSWORD 'strong_prod_password';
CREATE DATABASE myapp_prod OWNER myapp_prod_user;
GRANT ALL PRIVILEGES ON DATABASE myapp_prod TO myapp_prod_user;
```

### Run Migrations

Using Flyway (common for Scala apps):

```bash
# From your local machine or CI/CD
flyway -url=jdbc:postgresql://postgres-server/myapp_dev \
       -user=myapp_dev_user \
       -password=dev_password \
       migrate
```

Or using your application (if migrations are built-in):

```bash
# Run migration job in Kubernetes
kubectl run migration-job \
  --image=your-registry/scala-app:v1.0.0 \
  --env="DB_HOST=postgres-external" \
  --env="DB_NAME=myapp_dev" \
  --command -- /app/run-migrations.sh
```

## CI/CD Integration

### GitLab CI Example

```yaml
# .gitlab-ci.yml
stages:
  - build
  - test
  - deploy

variables:
  DOCKER_REGISTRY: your-registry.io
  APP_NAME: scala-app

build:
  stage: build
  script:
    - sbt clean compile test package
    - docker build -t $DOCKER_REGISTRY/$APP_NAME:$CI_COMMIT_SHA .
    - docker push $DOCKER_REGISTRY/$APP_NAME:$CI_COMMIT_SHA

deploy_dev:
  stage: deploy
  only:
    - develop
  script:
    - docker tag $DOCKER_REGISTRY/$APP_NAME:$CI_COMMIT_SHA $DOCKER_REGISTRY/$APP_NAME:dev-latest
    - docker push $DOCKER_REGISTRY/$APP_NAME:dev-latest
    - ./deploy.sh dev --skip-validation

deploy_stage:
  stage: deploy
  only:
    - main
  script:
    - docker tag $DOCKER_REGISTRY/$APP_NAME:$CI_COMMIT_SHA $DOCKER_REGISTRY/$APP_NAME:stage-$CI_COMMIT_TAG
    - docker push $DOCKER_REGISTRY/$APP_NAME:stage-$CI_COMMIT_TAG
    - ./deploy.sh stage

deploy_prod:
  stage: deploy
  when: manual
  only:
    - tags
  script:
    - docker tag $DOCKER_REGISTRY/$APP_NAME:$CI_COMMIT_SHA $DOCKER_REGISTRY/$APP_NAME:$CI_COMMIT_TAG
    - docker push $DOCKER_REGISTRY/$APP_NAME:$CI_COMMIT_TAG
    - ./deploy.sh prod
```

### GitHub Actions Example

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main, develop]
    tags: ['v*']

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Set up JDK
        uses: actions/setup-java@v3
        with:
          java-version: '17'
          distribution: 'temurin'

      - name: Build with sbt
        run: sbt clean compile test package

      - name: Build Docker image
        run: |
          docker build -t ${{ secrets.DOCKER_REGISTRY }}/scala-app:${{ github.sha }} .
          docker push ${{ secrets.DOCKER_REGISTRY }}/scala-app:${{ github.sha }}

      - name: Deploy to Dev
        if: github.ref == 'refs/heads/develop'
        run: |
          docker tag ${{ secrets.DOCKER_REGISTRY }}/scala-app:${{ github.sha }} \
                     ${{ secrets.DOCKER_REGISTRY }}/scala-app:dev-latest
          docker push ${{ secrets.DOCKER_REGISTRY }}/scala-app:dev-latest
          ./deploy.sh dev

      - name: Deploy to Production
        if: startsWith(github.ref, 'refs/tags/v')
        run: |
          docker tag ${{ secrets.DOCKER_REGISTRY }}/scala-app:${{ github.sha }} \
                     ${{ secrets.DOCKER_REGISTRY }}/scala-app:${{ github.ref_name }}
          docker push ${{ secrets.DOCKER_REGISTRY }}/scala-app:${{ github.ref_name }}
          ./deploy.sh prod
```

## Monitoring

### View Logs

```bash
# All pods in dev
kubectl logs -n dev -l app=app --tail=100 -f

# Specific pod
kubectl logs -n dev <pod-name> -f

# Previous instance (after crash)
kubectl logs -n dev <pod-name> --previous
```

### Check Metrics

```bash
# Pod resource usage
kubectl top pods -n dev

# Node resource usage
kubectl top nodes
```

### Events

```bash
# Recent events
kubectl get events -n dev --sort-by='.lastTimestamp' | tail -20

# Watch events
kubectl get events -n dev --watch
```

## Common Issues

### Pod CrashLoopBackOff

```bash
# Check logs
kubectl logs -n dev <pod-name>

# Check events
kubectl describe pod -n dev <pod-name>

# Common causes:
# 1. Application fails to start (check logs)
# 2. Health checks fail too quickly (adjust initialDelaySeconds)
# 3. Database connection fails (check secrets and network)
```

### ImagePullBackOff

```bash
# Check image name and tag
kubectl describe pod -n dev <pod-name>

# Verify image exists in registry
docker pull your-registry/scala-app:dev-latest

# Check image pull secrets
kubectl get secret registry-credentials -n dev
```

### Database Connection Issues

```bash
# Test DNS resolution from pod
kubectl run -it --rm debug --image=busybox -n dev -- nslookup postgres-external

# Test connectivity
kubectl run -it --rm debug --image=postgres:15 -n dev -- \
  psql -h postgres-external -U your_user -d your_db

# Check network policies
kubectl get networkpolicies -n dev
```

## Rollback Procedure

```bash
# Quick rollback
./deploy.sh <env> --rollback

# Or manual rollback
kubectl rollout undo deployment/<deployment-name> -n <namespace>

# Rollback to specific revision
kubectl rollout history deployment/<deployment-name> -n <namespace>
kubectl rollout undo deployment/<deployment-name> --to-revision=<number> -n <namespace>
```

## Best Practices

1. **Always test in dev first**: Never deploy directly to production
2. **Use specific version tags**: Tag images with version numbers or git SHA
3. **Monitor deployments**: Watch logs during rollout
4. **Gradual rollout**: Use rolling updates with proper health checks
5. **Keep secrets secure**: Never commit secrets to Git
6. **Document changes**: Update version tags and deployment notes
7. **Test rollbacks**: Practice rollback procedure in dev/stage
8. **Resource limits**: Set appropriate CPU/memory limits
9. **Database migrations**: Run migrations before deploying new code
10. **Monitoring**: Set up alerts for pod failures and errors
