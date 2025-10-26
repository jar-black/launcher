#!/bin/bash

# Secret Management Script
# Helps create, update, and manage Kubernetes secrets across environments

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
K8S_DIR="${PROJECT_ROOT}/k8s"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat <<EOF
Secret Management Script

Usage: $0 <command> [options]

Commands:
    init <env>              Initialize secrets file for environment
    validate <env>          Validate secrets file
    create <env>            Create secrets in Kubernetes cluster
    update <env>            Update secrets in Kubernetes cluster
    delete <env>            Delete secrets from Kubernetes cluster
    view <env>              View current secrets (base64 decoded)
    rotate <env> <key>      Rotate a specific secret key

Environments:
    dev, stage, prod

Examples:
    $0 init dev
    $0 validate prod
    $0 create stage
    $0 view dev
    $0 rotate prod db.password

EOF
    exit 0
}

init_secrets() {
    local env=$1
    local secrets_file="${K8S_DIR}/overlays/${env}/secrets.env"

    if [[ -f "${secrets_file}" ]]; then
        print_warning "Secrets file already exists: ${secrets_file}"
        read -p "Overwrite? (y/n): " confirm
        if [[ "${confirm}" != "y" ]]; then
            print_info "Cancelled"
            exit 0
        fi
    fi

    cp "${K8S_DIR}/secrets/secrets.env.example" "${secrets_file}"
    print_success "Created secrets file: ${secrets_file}"
    print_warning "Please edit this file and add your actual secret values"
    print_info "File location: ${secrets_file}"
}

validate_secrets() {
    local env=$1
    local secrets_file="${K8S_DIR}/overlays/${env}/secrets.env"

    print_info "Validating secrets for ${env}..."

    if [[ ! -f "${secrets_file}" ]]; then
        print_error "Secrets file not found: ${secrets_file}"
        print_info "Run: $0 init ${env}"
        exit 1
    fi

    # Check for empty values
    if grep -q "=\s*$" "${secrets_file}"; then
        print_error "Found empty secret values"
        exit 1
    fi

    # Check for example/placeholder values
    if grep -q "your_\|example\|placeholder\|CHANGE_ME" "${secrets_file}"; then
        print_warning "Found placeholder values in secrets file"
        if [[ "${env}" == "prod" ]]; then
            print_error "Cannot use placeholder values in production!"
            exit 1
        fi
    fi

    # Validate format
    if ! grep -qE "^[a-zA-Z0-9._-]+=" "${secrets_file}"; then
        print_error "Invalid secret file format"
        exit 1
    fi

    print_success "Secrets validation passed"
}

create_secrets() {
    local env=$1
    local namespace

    case "${env}" in
        dev)   namespace="dev" ;;
        stage) namespace="stage" ;;
        prod)  namespace="production" ;;
        *)     print_error "Invalid environment"; exit 1 ;;
    esac

    validate_secrets "${env}"

    print_info "Creating secrets in ${env} (namespace: ${namespace})..."

    # Check if namespace exists
    if ! kubectl get namespace "${namespace}" &> /dev/null; then
        print_warning "Namespace ${namespace} does not exist"
        read -p "Create namespace? (y/n): " confirm
        if [[ "${confirm}" == "y" ]]; then
            kubectl create namespace "${namespace}"
            print_success "Created namespace: ${namespace}"
        else
            exit 1
        fi
    fi

    # Create secret using kustomize
    kubectl kustomize "${K8S_DIR}/overlays/${env}" | \
        kubectl apply -f - --dry-run=client -o yaml | \
        kubectl apply -f -

    print_success "Secrets created/updated in ${env}"
}

update_secrets() {
    create_secrets "$1"
}

delete_secrets() {
    local env=$1
    local namespace

    case "${env}" in
        dev)   namespace="dev" ;;
        stage) namespace="stage" ;;
        prod)  namespace="production" ;;
        *)     print_error "Invalid environment"; exit 1 ;;
    esac

    print_warning "This will delete all secrets in ${env}"
    read -p "Are you sure? (type 'yes' to confirm): " confirm

    if [[ "${confirm}" != "yes" ]]; then
        print_info "Cancelled"
        exit 0
    fi

    kubectl delete secret --all -n "${namespace}"
    print_success "Secrets deleted from ${env}"
}

view_secrets() {
    local env=$1
    local namespace

    case "${env}" in
        dev)   namespace="dev" ;;
        stage) namespace="stage" ;;
        prod)  namespace="production" ;;
        *)     print_error "Invalid environment"; exit 1 ;;
    esac

    print_info "Viewing secrets in ${env}..."

    # List all secrets
    local secrets=$(kubectl get secrets -n "${namespace}" -o jsonpath='{.items[*].metadata.name}')

    for secret in ${secrets}; do
        if [[ "${secret}" == *"app-secrets"* ]]; then
            echo ""
            print_info "Secret: ${secret}"
            echo "----------------------------------------"

            # Get and decode secret data
            kubectl get secret "${secret}" -n "${namespace}" -o json | \
                jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'

            echo "----------------------------------------"
        fi
    done
}

rotate_secret() {
    local env=$1
    local key=$2

    print_warning "Rotating secret key: ${key} in ${env}"
    print_info "Please enter the new value for ${key}:"
    read -s new_value
    echo ""

    local secrets_file="${K8S_DIR}/overlays/${env}/secrets.env"

    if [[ ! -f "${secrets_file}" ]]; then
        print_error "Secrets file not found: ${secrets_file}"
        exit 1
    fi

    # Update the secret in the file
    sed -i "s|^${key}=.*|${key}=${new_value}|" "${secrets_file}"

    print_success "Updated ${key} in ${secrets_file}"
    print_info "Now apply the changes with: kubectl apply -k k8s/overlays/${env}"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    local command=$1
    shift

    case "${command}" in
        init)
            [[ $# -lt 1 ]] && usage
            init_secrets "$1"
            ;;
        validate)
            [[ $# -lt 1 ]] && usage
            validate_secrets "$1"
            ;;
        create)
            [[ $# -lt 1 ]] && usage
            create_secrets "$1"
            ;;
        update)
            [[ $# -lt 1 ]] && usage
            update_secrets "$1"
            ;;
        delete)
            [[ $# -lt 1 ]] && usage
            delete_secrets "$1"
            ;;
        view)
            [[ $# -lt 1 ]] && usage
            view_secrets "$1"
            ;;
        rotate)
            [[ $# -lt 2 ]] && usage
            rotate_secret "$1" "$2"
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown command: ${command}"
            usage
            ;;
    esac
}

main "$@"
