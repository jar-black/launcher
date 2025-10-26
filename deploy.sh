#!/bin/bash

# Kubernetes Deployment Script with Validation
# Usage: ./deploy.sh <environment> [options]
# Example: ./deploy.sh dev
#          ./deploy.sh prod --dry-run
#          ./deploy.sh stage --rollback

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
VALID_ENVIRONMENTS=("dev" "stage" "prod")

# Functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat <<EOF
Kubernetes Deployment Script

Usage: $0 <environment> [options]

Environments:
    dev     - Development environment
    stage   - Staging environment
    prod    - Production environment

Options:
    --dry-run         Validate manifests without applying
    --rollback        Rollback to previous deployment
    --diff            Show differences before applying
    --skip-validation Skip pre-deployment validation
    -h, --help        Show this help message

Examples:
    $0 dev
    $0 prod --dry-run
    $0 stage --diff
    $0 prod --rollback

EOF
    exit 0
}

check_requirements() {
    print_info "Checking requirements..."

    local missing_tools=()

    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi

    if ! command -v kustomize &> /dev/null; then
        print_warning "kustomize not found, will use kubectl kustomize instead"
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    print_success "All requirements met"
}

validate_environment() {
    local env=$1

    if [[ ! " ${VALID_ENVIRONMENTS[@]} " =~ " ${env} " ]]; then
        print_error "Invalid environment: ${env}"
        print_info "Valid environments: ${VALID_ENVIRONMENTS[*]}"
        exit 1
    fi
}

check_kubectl_context() {
    local env=$1
    local current_context

    current_context=$(kubectl config current-context)
    print_info "Current kubectl context: ${current_context}"

    # Production safety check
    if [[ "${env}" == "prod" ]]; then
        print_warning "You are about to deploy to PRODUCTION!"
        print_warning "Current context: ${current_context}"
        read -p "Are you sure you want to continue? (type 'yes' to proceed): " confirmation

        if [[ "${confirmation}" != "yes" ]]; then
            print_info "Deployment cancelled"
            exit 0
        fi
    fi
}

validate_secrets() {
    local env=$1
    local secrets_file="${K8S_DIR}/overlays/${env}/secrets.env"

    print_info "Validating secrets for ${env}..."

    if [[ ! -f "${secrets_file}" ]]; then
        print_error "Secrets file not found: ${secrets_file}"
        print_info "Please create the secrets file. See secrets/secrets.env.example"
        exit 1
    fi

    # Check for placeholder values in production
    if [[ "${env}" == "prod" ]]; then
        if grep -q "CHANGE_ME\|placeholder" "${secrets_file}"; then
            print_error "Found placeholder values in production secrets!"
            print_error "Please update all secret values before deploying to production"
            exit 1
        fi
    fi

    print_success "Secrets validation passed"
}

validate_image_tag() {
    local env=$1
    local kustomization="${K8S_DIR}/overlays/${env}/kustomization.yaml"

    print_info "Validating image tags for ${env}..."

    # Production should never use :latest
    if [[ "${env}" == "prod" ]]; then
        if grep -q "newTag:.*latest" "${kustomization}"; then
            print_error "Production deployment cannot use :latest tag!"
            print_error "Please specify a specific version tag"
            exit 1
        fi
    fi

    print_success "Image tag validation passed"
}

build_manifests() {
    local env=$1
    local output_file="${SCRIPT_DIR}/manifests-${env}.yaml"

    print_info "Building manifests for ${env}..."

    kubectl kustomize "${K8S_DIR}/overlays/${env}" > "${output_file}"

    print_success "Manifests built: ${output_file}"
    echo "${output_file}"
}

dry_run_deployment() {
    local env=$1

    print_info "Running dry-run validation..."

    kubectl kustomize "${K8S_DIR}/overlays/${env}" | kubectl apply --dry-run=client -f -

    if [[ $? -eq 0 ]]; then
        print_success "Dry-run validation passed"
    else
        print_error "Dry-run validation failed"
        exit 1
    fi
}

show_diff() {
    local env=$1

    print_info "Showing differences..."

    kubectl kustomize "${K8S_DIR}/overlays/${env}" | kubectl diff -f - || true
}

backup_current_state() {
    local env=$1
    local namespace

    case "${env}" in
        dev)   namespace="dev" ;;
        stage) namespace="stage" ;;
        prod)  namespace="production" ;;
    esac

    local backup_dir="${SCRIPT_DIR}/backups/${env}"
    mkdir -p "${backup_dir}"

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${backup_dir}/backup-${timestamp}.yaml"

    print_info "Backing up current state..."

    if kubectl get namespace "${namespace}" &> /dev/null; then
        kubectl get all,configmap,secret,ingress -n "${namespace}" -o yaml > "${backup_file}" 2>/dev/null || true
        print_success "Backup saved: ${backup_file}"
    else
        print_warning "Namespace ${namespace} does not exist, skipping backup"
    fi
}

deploy() {
    local env=$1

    print_info "Deploying to ${env}..."

    kubectl apply -k "${K8S_DIR}/overlays/${env}"

    if [[ $? -eq 0 ]]; then
        print_success "Deployment applied successfully"
    else
        print_error "Deployment failed"
        exit 1
    fi
}

wait_for_rollout() {
    local env=$1
    local namespace

    case "${env}" in
        dev)   namespace="dev" ;;
        stage) namespace="stage" ;;
        prod)  namespace="production" ;;
    esac

    print_info "Waiting for rollout to complete..."

    # Get all deployments in namespace
    local deployments=$(kubectl get deployments -n "${namespace}" -o jsonpath='{.items[*].metadata.name}')

    for deployment in ${deployments}; do
        print_info "Waiting for deployment: ${deployment}"
        kubectl rollout status deployment/"${deployment}" -n "${namespace}" --timeout=5m

        if [[ $? -ne 0 ]]; then
            print_error "Rollout failed for ${deployment}"
            print_info "Consider rolling back with: $0 ${env} --rollback"
            exit 1
        fi
    done

    print_success "All deployments rolled out successfully"
}

rollback_deployment() {
    local env=$1
    local namespace

    case "${env}" in
        dev)   namespace="dev" ;;
        stage) namespace="stage" ;;
        prod)  namespace="production" ;;
    esac

    print_warning "Rolling back deployment in ${env}..."

    # Get all deployments in namespace
    local deployments=$(kubectl get deployments -n "${namespace}" -o jsonpath='{.items[*].metadata.name}')

    for deployment in ${deployments}; do
        print_info "Rolling back: ${deployment}"
        kubectl rollout undo deployment/"${deployment}" -n "${namespace}"
    done

    print_success "Rollback completed"
}

show_status() {
    local env=$1
    local namespace

    case "${env}" in
        dev)   namespace="dev" ;;
        stage) namespace="stage" ;;
        prod)  namespace="production" ;;
    esac

    print_info "Deployment status for ${env}:"
    echo ""

    kubectl get all,ingress,configmap -n "${namespace}"
}

# Main script
main() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    local environment=""
    local dry_run=false
    local rollback=false
    local show_diff_only=false
    local skip_validation=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --rollback)
                rollback=true
                shift
                ;;
            --diff)
                show_diff_only=true
                shift
                ;;
            --skip-validation)
                skip_validation=true
                shift
                ;;
            *)
                if [[ -z "${environment}" ]]; then
                    environment=$1
                else
                    print_error "Unknown option: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${environment}" ]]; then
        print_error "Environment not specified"
        usage
    fi

    # Header
    echo ""
    echo "═══════════════════════════════════════"
    echo "  Kubernetes Deployment Script"
    echo "═══════════════════════════════════════"
    echo ""

    # Validate environment
    validate_environment "${environment}"

    # Check requirements
    check_requirements

    # Handle rollback
    if [[ "${rollback}" == true ]]; then
        check_kubectl_context "${environment}"
        rollback_deployment "${environment}"
        show_status "${environment}"
        exit 0
    fi

    # Handle diff only
    if [[ "${show_diff_only}" == true ]]; then
        show_diff "${environment}"
        exit 0
    fi

    # Check kubectl context
    check_kubectl_context "${environment}"

    # Validation steps
    if [[ "${skip_validation}" == false ]]; then
        validate_secrets "${environment}"
        validate_image_tag "${environment}"
        dry_run_deployment "${environment}"
    fi

    # Dry run mode
    if [[ "${dry_run}" == true ]]; then
        print_info "Dry-run mode - no changes will be applied"
        manifest_file=$(build_manifests "${environment}")
        print_success "Dry-run completed successfully"
        print_info "Generated manifests: ${manifest_file}"
        exit 0
    fi

    # Backup current state
    backup_current_state "${environment}"

    # Deploy
    deploy "${environment}"

    # Wait for rollout
    wait_for_rollout "${environment}"

    # Show final status
    echo ""
    show_status "${environment}"

    echo ""
    print_success "Deployment completed successfully!"
    echo ""
}

# Run main function
main "$@"
