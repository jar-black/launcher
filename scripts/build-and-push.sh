#!/bin/bash

# Build and Push Docker Image Script
# Usage: ./build-and-push.sh <version> <environment>
# Example: ./build-and-push.sh v1.2.3 dev

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat <<EOF
Build and Push Docker Image

Usage: $0 <version> <environment> [options]

Arguments:
    version        Version tag (e.g., v1.2.3, 1.0.0)
    environment    Target environment (dev, stage, prod)

Options:
    --registry <url>    Docker registry URL (default: docker.io)
    --app-name <name>   Application name (default: scala-app)
    --no-cache          Build without cache
    --skip-tests        Skip running tests before build
    --skip-push         Build only, don't push
    -h, --help          Show this help

Examples:
    $0 v1.2.3 dev
    $0 1.0.0 prod --registry myregistry.io
    $0 v1.2.3 dev --no-cache --skip-tests

EOF
    exit 0
}

# Default values
REGISTRY="docker.io"
APP_NAME="scala-app"
NO_CACHE=""
SKIP_TESTS=false
SKIP_PUSH=false

# Parse arguments
if [[ $# -lt 2 ]]; then
    usage
fi

VERSION=$1
ENVIRONMENT=$2
shift 2

while [[ $# -gt 0 ]]; do
    case $1 in
        --registry)
            REGISTRY=$2
            shift 2
            ;;
        --app-name)
            APP_NAME=$2
            shift 2
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --skip-push)
            SKIP_PUSH=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate environment
if [[ ! "${ENVIRONMENT}" =~ ^(dev|stage|prod)$ ]]; then
    print_error "Invalid environment: ${ENVIRONMENT}"
    print_info "Valid environments: dev, stage, prod"
    exit 1
fi

# Construct image name
IMAGE_NAME="${REGISTRY}/${APP_NAME}"
FULL_IMAGE="${IMAGE_NAME}:${VERSION}"
ENV_TAG="${ENVIRONMENT}-${VERSION}"
ENV_LATEST="${ENVIRONMENT}-latest"

print_info "Building Docker image for ${APP_NAME}"
echo "  Registry: ${REGISTRY}"
echo "  Version: ${VERSION}"
echo "  Environment: ${ENVIRONMENT}"
echo "  Full image: ${FULL_IMAGE}"
echo ""

# Check if Dockerfile exists
if [[ ! -f "Dockerfile" ]]; then
    print_error "Dockerfile not found in current directory"
    exit 1
fi

# Run tests
if [[ "${SKIP_TESTS}" == false ]]; then
    print_info "Running tests..."

    if [[ -f "build.sbt" ]]; then
        # Scala/SBT project
        sbt clean test
    elif [[ -f "pom.xml" ]]; then
        # Maven project
        mvn clean test
    elif [[ -f "build.gradle" ]] || [[ -f "build.gradle.kts" ]]; then
        # Gradle project
        ./gradlew clean test
    else
        print_warning "No build file found, skipping tests"
    fi

    print_success "Tests passed"
fi

# Build application
print_info "Building application..."

if [[ -f "build.sbt" ]]; then
    sbt clean compile package
elif [[ -f "pom.xml" ]]; then
    mvn clean package
elif [[ -f "build.gradle" ]] || [[ -f "build.gradle.kts" ]]; then
    ./gradlew clean build
fi

print_success "Application built"

# Build Docker image
print_info "Building Docker image: ${FULL_IMAGE}"

docker build ${NO_CACHE} -t "${FULL_IMAGE}" .

if [[ $? -ne 0 ]]; then
    print_error "Docker build failed"
    exit 1
fi

print_success "Docker image built: ${FULL_IMAGE}"

# Tag for environment
print_info "Tagging image for environment..."

docker tag "${FULL_IMAGE}" "${IMAGE_NAME}:${ENV_TAG}"
docker tag "${FULL_IMAGE}" "${IMAGE_NAME}:${ENV_LATEST}"

# Additional tags for production
if [[ "${ENVIRONMENT}" == "prod" ]]; then
    docker tag "${FULL_IMAGE}" "${IMAGE_NAME}:latest"
    print_info "Tagged as: ${IMAGE_NAME}:latest"
fi

print_success "Tagged as: ${IMAGE_NAME}:${ENV_TAG}"
print_success "Tagged as: ${IMAGE_NAME}:${ENV_LATEST}"

# Push images
if [[ "${SKIP_PUSH}" == false ]]; then
    print_info "Pushing images to registry..."

    # Check if logged in
    if ! docker info &> /dev/null; then
        print_error "Docker daemon not running or not logged in"
        exit 1
    fi

    # Push all tags
    docker push "${FULL_IMAGE}"
    docker push "${IMAGE_NAME}:${ENV_TAG}"
    docker push "${IMAGE_NAME}:${ENV_LATEST}"

    if [[ "${ENVIRONMENT}" == "prod" ]]; then
        docker push "${IMAGE_NAME}:latest"
    fi

    print_success "Images pushed to registry"
else
    print_warning "Skipping push (--skip-push specified)"
fi

# Update kustomization file
print_info "Updating kustomization file..."

KUSTOMIZATION_FILE="k8s/overlays/${ENVIRONMENT}/kustomization.yaml"

if [[ -f "${KUSTOMIZATION_FILE}" ]]; then
    # Backup original
    cp "${KUSTOMIZATION_FILE}" "${KUSTOMIZATION_FILE}.backup"

    # Update image tag
    sed -i "s|newTag:.*|newTag: \"${ENV_TAG}\"|g" "${KUSTOMIZATION_FILE}"

    print_success "Updated ${KUSTOMIZATION_FILE}"
    print_info "Old file backed up as ${KUSTOMIZATION_FILE}.backup"
else
    print_warning "Kustomization file not found: ${KUSTOMIZATION_FILE}"
fi

# Summary
echo ""
print_success "Build and push completed!"
echo ""
echo "Images created:"
echo "  - ${FULL_IMAGE}"
echo "  - ${IMAGE_NAME}:${ENV_TAG}"
echo "  - ${IMAGE_NAME}:${ENV_LATEST}"
if [[ "${ENVIRONMENT}" == "prod" ]]; then
    echo "  - ${IMAGE_NAME}:latest"
fi
echo ""
print_info "Next steps:"
echo "  1. Review changes in ${KUSTOMIZATION_FILE}"
echo "  2. Deploy with: ./deploy.sh ${ENVIRONMENT}"
echo ""
