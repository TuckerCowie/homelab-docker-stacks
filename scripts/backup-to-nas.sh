#!/bin/bash
# =============================================================================
# Homelab Backup Script
# =============================================================================
# Creates backups of Docker configs and LXC configurations to Synology NAS.
# Run via cron on Proxmox host.
#
# Usage: ./backup-to-nas.sh [--docker-only] [--lxc-only]
# =============================================================================

set -euo pipefail

# Configuration
BACKUP_BASE="/mnt/synology/backups"
DOCKER_DATA="/mnt/synology/docker-data"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# =============================================================================
# BACKUP DOCKER CONFIGS
# =============================================================================
backup_docker_configs() {
    log_info "=== Backing up Docker configurations ==="
    
    DOCKER_BACKUP_DIR="${BACKUP_BASE}/docker/${DATE}"
    mkdir -p "$DOCKER_BACKUP_DIR"
    
    # Services to backup (config directories)
    SERVICES=(
        sonarr radarr prowlarr qbittorrent gluetun
        bazarr jellyseerr tdarr unpackerr notifiarr flaresolverr profilarr
        tandoor tandoor-db
        jellyfin
    )
    
    for service in "${SERVICES[@]}"; do
        SERVICE_PATH="${DOCKER_DATA}/${service}"
        if [[ -d "$SERVICE_PATH" ]]; then
            log_info "Backing up $service..."
            tar -czf "${DOCKER_BACKUP_DIR}/${service}.tar.gz" \
                -C "$DOCKER_DATA" "$service" 2>/dev/null || {
                log_warn "Failed to backup $service"
            }
        else
            log_warn "Service directory not found: $service"
        fi
    done
    
    # Create manifest
    cat > "${DOCKER_BACKUP_DIR}/manifest.txt" << EOF
Backup Date: $(date)
Hostname: $(hostname)
Services: ${SERVICES[*]}
EOF
    
    log_info "Docker backups saved to: $DOCKER_BACKUP_DIR"
}

# =============================================================================
# BACKUP LXC CONFIGURATIONS
# =============================================================================
backup_lxc_configs() {
    log_info "=== Backing up LXC configurations ==="
    
    LXC_BACKUP_DIR="${BACKUP_BASE}/lxc/${DATE}"
    mkdir -p "$LXC_BACKUP_DIR"
    
    # Backup all LXC configs
    if [[ -d /etc/pve/lxc ]]; then
        for conf in /etc/pve/lxc/*.conf; do
            if [[ -f "$conf" ]]; then
                CTID=$(basename "$conf" .conf)
                log_info "Backing up LXC $CTID config..."
                cp "$conf" "${LXC_BACKUP_DIR}/${CTID}.conf"
            fi
        done
    fi
    
    # Backup VM configs
    if [[ -d /etc/pve/qemu-server ]]; then
        for conf in /etc/pve/qemu-server/*.conf; do
            if [[ -f "$conf" ]]; then
                VMID=$(basename "$conf" .conf)
                log_info "Backing up VM $VMID config..."
                cp "$conf" "${LXC_BACKUP_DIR}/vm-${VMID}.conf"
            fi
        done
    fi
    
    log_info "LXC/VM configs saved to: $LXC_BACKUP_DIR"
}

# =============================================================================
# BACKUP PROXMOX HOST CONFIGS
# =============================================================================
backup_host_configs() {
    log_info "=== Backing up Proxmox host configurations ==="
    
    HOST_BACKUP_DIR="${BACKUP_BASE}/host/${DATE}"
    mkdir -p "$HOST_BACKUP_DIR"
    
    # Important host files
    FILES=(
        /etc/fstab
        /etc/network/interfaces
        /etc/hosts
        /etc/subuid
        /etc/subgid
    )
    
    for file in "${FILES[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "${HOST_BACKUP_DIR}/$(basename "$file")"
        fi
    done
    
    # Export package list
    dpkg --get-selections > "${HOST_BACKUP_DIR}/packages.list"
    
    log_info "Host configs saved to: $HOST_BACKUP_DIR"
}

# =============================================================================
# CLEANUP OLD BACKUPS
# =============================================================================
cleanup_old_backups() {
    log_info "=== Cleaning up backups older than $RETENTION_DAYS days ==="
    
    for backup_type in docker lxc host; do
        BACKUP_PATH="${BACKUP_BASE}/${backup_type}"
        if [[ -d "$BACKUP_PATH" ]]; then
            find "$BACKUP_PATH" -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true
        fi
    done
    
    log_info "Cleanup complete"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    log_info "Starting homelab backup - $(date)"
    
    # Check backup destination
    if [[ ! -d "$BACKUP_BASE" ]]; then
        log_error "Backup destination not available: $BACKUP_BASE"
        log_error "Is NFS mounted?"
        exit 1
    fi
    
    # Parse arguments
    DOCKER_ONLY=false
    LXC_ONLY=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --docker-only)
                DOCKER_ONLY=true
                shift
                ;;
            --lxc-only)
                LXC_ONLY=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Run backups
    if [[ "$LXC_ONLY" == false ]]; then
        backup_docker_configs
    fi
    
    if [[ "$DOCKER_ONLY" == false ]]; then
        backup_lxc_configs
        backup_host_configs
    fi
    
    cleanup_old_backups
    
    log_info "Backup complete - $(date)"
    
    # Show disk usage
    echo ""
    log_info "Backup storage usage:"
    du -sh "${BACKUP_BASE}"/* 2>/dev/null || true
}

main "$@"
