#!/bin/bash
# =============================================================================
# Deploy Docker Stacks to Docker LXC
# =============================================================================
# Copies compose files and environment to Docker LXC and starts services.
# Run from Proxmox host.
#
# Usage: ./deploy-stacks.sh [--stack <name>] [--restart]
# =============================================================================

set -euo pipefail

# Configuration
DOCKER_LXC_CTID="${DOCKER_LXC_CTID:-103}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# FUNCTIONS
# =============================================================================

check_lxc_running() {
    local status
    status=$(pct status "$DOCKER_LXC_CTID" 2>/dev/null | awk '{print $2}') || status="unknown"
    
    if [[ "$status" != "running" ]]; then
        log_error "Docker LXC ($DOCKER_LXC_CTID) is not running (status: $status)"
        exit 1
    fi
}

deploy_env() {
    log_info "Deploying environment file..."
    
    if [[ ! -f "${REPO_ROOT}/.env" ]]; then
        log_error ".env file not found. Copy .env.example to .env and configure."
        exit 1
    fi
    
    pct push "$DOCKER_LXC_CTID" "${REPO_ROOT}/.env" /opt/stacks/.env
    pct exec "$DOCKER_LXC_CTID" -- chmod 600 /opt/stacks/.env
}

deploy_stack() {
    local stack="$1"
    local compose_file="${REPO_ROOT}/docker/${stack}/docker-compose.yml"
    
    if [[ ! -f "$compose_file" ]]; then
        log_error "Compose file not found: $compose_file"
        return 1
    fi
    
    log_info "Deploying $stack..."
    
    # Create stack directory
    pct exec "$DOCKER_LXC_CTID" -- mkdir -p "/opt/stacks/${stack}"
    
    # Copy compose file
    pct push "$DOCKER_LXC_CTID" "$compose_file" "/opt/stacks/${stack}/docker-compose.yml"
    
    # Link env file
    pct exec "$DOCKER_LXC_CTID" -- bash -c "
        cd /opt/stacks/${stack}
        ln -sf /opt/stacks/.env .env
    "
    
    log_info "$stack deployed"
}

start_stack() {
    local stack="$1"
    local restart="$2"
    
    log_info "Starting $stack..."
    
    pct exec "$DOCKER_LXC_CTID" -- bash -c "
        cd /opt/stacks/${stack}
        if [[ '$restart' == 'true' ]]; then
            docker compose down
        fi
        docker compose up -d
    "
    
    # Wait a moment for containers to start
    sleep 5
    
    # Show status
    log_info "$stack containers:"
    pct exec "$DOCKER_LXC_CTID" -- bash -c "
        cd /opt/stacks/${stack}
        docker compose ps
    "
}

deploy_all() {
    local restart="$1"
    
    deploy_env
    
    # Deploy in order (dependencies first)
    local stacks=(arr-stack support-services tandoor)
    
    for stack in "${stacks[@]}"; do
        deploy_stack "$stack"
    done
    
    # Start in order
    for stack in "${stacks[@]}"; do
        start_stack "$stack" "$restart"
        echo ""
    done
}

show_status() {
    log_info "Docker container status:"
    pct exec "$DOCKER_LXC_CTID" -- docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local stack=""
    local restart=false
    local status_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --stack)
                stack="$2"
                shift 2
                ;;
            --restart)
                restart=true
                shift
                ;;
            --status)
                status_only=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: $0 [--stack <name>] [--restart] [--status]"
                exit 1
                ;;
        esac
    done
    
    # Check LXC is running
    check_lxc_running
    
    if [[ "$status_only" == true ]]; then
        show_status
        exit 0
    fi
    
    if [[ -n "$stack" ]]; then
        # Deploy single stack
        deploy_env
        deploy_stack "$stack"
        start_stack "$stack" "$restart"
    else
        # Deploy all stacks
        deploy_all "$restart"
    fi
    
    echo ""
    log_info "Deployment complete!"
    show_status
}

main "$@"
