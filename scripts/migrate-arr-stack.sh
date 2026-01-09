#!/bin/bash
# =============================================================================
# Arr Stack Migration Script
# =============================================================================
# Surgically migrates volumes and configs from an old Docker VM to the new
# stack. Handles both Docker volumes and bind mounts.
#
# Usage:
#   ./migrate-arr-stack.sh [options]
#
# Options:
#   --old-vm-ip <IP>        IP address of old Docker VM (for SSH access)
#   --old-vm-user <user>    SSH user for old VM (default: root)
#   --old-vm-ssh-key <path> Path to SSH key for old VM
#   --old-vm-path <path>    Direct path to old volumes (if accessible locally)
#   --dry-run               Show what would be done without making changes
#   --skip-backup           Skip creating backup before migration
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

# Load environment variables
if [[ -f "$ENV_FILE" ]]; then
    set +u
    source "$ENV_FILE"
    set -u
fi

# Default values
OLD_VM_IP=""
OLD_VM_USER="${OLD_VM_USER:-root}"
OLD_VM_SSH_KEY=""
OLD_VM_PATH=""
DRY_RUN=false
SKIP_BACKUP=false

# New stack paths (NFS mounted)
NEW_BASE_PATH="${NEW_BASE_PATH:-/mnt/docker-data}"
NEW_STACK_PATH="${NEW_STACK_PATH:-/opt/stacks/arr-stack}"

# Services to migrate (matching docker-compose.yml)
declare -A SERVICE_PATHS=(
    ["sonarr"]="/config"
    ["radarr"]="/config"
    ["prowlarr"]="/config"
    ["qbittorrent"]="/config"
    ["gluetun"]="/gluetun"
    ["bazarr"]="/config"
    ["jellyseerr"]="/app/config"
    ["tdarr"]="/app"  # Special handling needed
    ["unpackerr"]="/config"
    ["notifiarr"]="/config"
    ["recyclarr"]="/config"
)

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --old-vm-ip)
            OLD_VM_IP="$2"
            shift 2
            ;;
        --old-vm-user)
            OLD_VM_USER="$2"
            shift 2
            ;;
        --old-vm-ssh-key)
            OLD_VM_SSH_KEY="$2"
            shift 2
            ;;
        --old-vm-path)
            OLD_VM_PATH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        -h|--help)
            cat << EOF
Arr Stack Migration Script

Usage: $0 [options]

Options:
  --old-vm-ip <IP>        IP address of old Docker VM (for SSH access)
  --old-vm-user <user>    SSH user for old VM (default: root)
  --old-vm-ssh-key <path>  Path to SSH key for old VM
  --old-vm-path <path>    Direct path to old volumes (if accessible locally)
  --dry-run               Show what would be done without making changes
  --skip-backup           Skip creating backup before migration
  -h, --help              Show this help message

Examples:
  # Migrate via SSH from old VM
  $0 --old-vm-ip 192.168.1.100 --old-vm-user root --old-vm-ssh-key ~/.ssh/id_rsa

  # Migrate from local path (if old volumes are mounted)
  $0 --old-vm-path /mnt/old-docker/volumes

  # Dry run to see what would happen
  $0 --old-vm-ip 192.168.1.100 --dry-run
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# VALIDATION
# =============================================================================
echo "=== Arr Stack Migration Script ==="
echo ""

if [[ -z "$OLD_VM_IP" && -z "$OLD_VM_PATH" ]]; then
    echo "ERROR: Must specify either --old-vm-ip or --old-vm-path"
    echo "Use --help for usage information"
    exit 1
fi

if [[ -n "$OLD_VM_IP" && -n "$OLD_VM_PATH" ]]; then
    echo "ERROR: Cannot specify both --old-vm-ip and --old-vm-path"
    exit 1
fi

# Check if new paths exist
if [[ ! -d "$NEW_BASE_PATH" ]]; then
    echo "ERROR: New base path does not exist: $NEW_BASE_PATH"
    echo "Make sure NFS mounts are set up correctly"
    exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "⚠️  DRY RUN MODE - No changes will be made"
    echo ""
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
log_info() {
    echo "ℹ️  $*"
}

log_success() {
    echo "✓ $*"
}

log_warning() {
    echo "⚠️  $*"
}

log_error() {
    echo "✗ $*" >&2
}

run_remote() {
    if [[ -n "$OLD_VM_IP" ]]; then
        local ssh_cmd="ssh"
        if [[ -n "$OLD_VM_SSH_KEY" ]]; then
            ssh_cmd="$ssh_cmd -i $OLD_VM_SSH_KEY"
        fi
        $ssh_cmd -o StrictHostKeyChecking=no "$OLD_VM_USER@$OLD_VM_IP" "$@"
    else
        # Local execution
        bash -c "$@"
    fi
}

find_old_volume() {
    local service=$1
    local container_name=$2
    
    log_info "Finding volume path for $service..."
    
    # Try to find via docker inspect
    local volume_path=$(run_remote "docker inspect $container_name 2>/dev/null | jq -r '.[0].Mounts[] | select(.Destination == \"${SERVICE_PATHS[$service]}\") | .Source' | head -1" || echo "")
    
    if [[ -n "$volume_path" && "$volume_path" != "null" ]]; then
        echo "$volume_path"
        return 0
    fi
    
    # Try common Docker volume locations
    local common_paths=(
        "/var/lib/docker/volumes"
        "/opt/docker/volumes"
        "/docker/volumes"
        "/mnt/docker-data"
        "/data/docker"
    )
    
    for base_path in "${common_paths[@]}"; do
        if run_remote "test -d $base_path/$service" 2>/dev/null; then
            echo "$base_path/$service"
            return 0
        fi
        if run_remote "test -d $base_path/${service}_data" 2>/dev/null; then
            echo "$base_path/${service}_data"
            return 0
        fi
    done
    
    # If OLD_VM_PATH is set, try that
    if [[ -n "$OLD_VM_PATH" ]]; then
        if [[ -d "$OLD_VM_PATH/$service" ]]; then
            echo "$OLD_VM_PATH/$service"
            return 0
        fi
        if [[ -d "$OLD_VM_PATH/${service}_data" ]]; then
            echo "$OLD_VM_PATH/${service}_data"
            return 0
        fi
    fi
    
    return 1
}

backup_service() {
    local service=$1
    local old_path=$2
    local backup_dir=$3
    
    log_info "Creating backup of $service..."
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "  Would create: $backup_dir/${service}.tar.gz"
        return 0
    fi
    
    if [[ -n "$OLD_VM_IP" ]]; then
        # Remote backup
        run_remote "tar -czf - -C $old_path . 2>/dev/null" > "$backup_dir/${service}.tar.gz"
    else
        # Local backup
        tar -czf "$backup_dir/${service}.tar.gz" -C "$old_path" . 2>/dev/null
    fi
    
    if [[ -f "$backup_dir/${service}.tar.gz" ]]; then
        local size=$(du -h "$backup_dir/${service}.tar.gz" | cut -f1)
        log_success "Backed up $service ($size)"
        return 0
    else
        log_error "Failed to backup $service"
        return 1
    fi
}

migrate_service() {
    local service=$1
    local old_path=$2
    local new_path=$3
    
    log_info "Migrating $service..."
    log_info "  From: $old_path"
    log_info "  To:   $new_path"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "  Would copy data from $old_path to $new_path"
        return 0
    fi
    
    # Create destination directory
    mkdir -p "$new_path"
    
    # Copy data using rsync for efficiency
    if [[ -n "$OLD_VM_IP" ]]; then
        # Remote to local via rsync
        local rsync_cmd="rsync -avz --progress"
        if [[ -n "$OLD_VM_SSH_KEY" ]]; then
            rsync_cmd="$rsync_cmd -e 'ssh -i $OLD_VM_SSH_KEY -o StrictHostKeyChecking=no'"
        else
            rsync_cmd="$rsync_cmd -e 'ssh -o StrictHostKeyChecking=no'"
        fi
        eval "$rsync_cmd $OLD_VM_USER@$OLD_VM_IP:$old_path/ $new_path/"
    else
        # Local copy
        rsync -avz --progress "$old_path/" "$new_path/"
    fi
    
    # Set permissions (use PUID/PGID from env if available)
    local uid="${PUID:-1000}"
    local gid="${PGID:-1000}"
    chown -R "$uid:$gid" "$new_path"
    
    log_success "Migrated $service"
}

verify_service() {
    local service=$1
    local new_path=$2
    
    log_info "Verifying $service migration..."
    
    # Check if directory exists and has content
    if [[ ! -d "$new_path" ]]; then
        log_error "$service: Destination directory does not exist"
        return 1
    fi
    
    local file_count=$(find "$new_path" -type f | wc -l)
    if [[ $file_count -eq 0 ]]; then
        log_warning "$service: Destination directory is empty"
        return 1
    fi
    
    # Check for key config files
    case $service in
        sonarr|radarr|prowlarr|bazarr)
            if [[ -f "$new_path/config.xml" ]]; then
                log_success "$service: Found config.xml"
            else
                log_warning "$service: config.xml not found (may be using SQLite)"
            fi
            ;;
        qbittorrent)
            if [[ -f "$new_path/qBittorrent.conf" ]]; then
                log_success "$service: Found qBittorrent.conf"
            else
                log_warning "$service: qBittorrent.conf not found"
            fi
            ;;
        jellyseerr)
            if [[ -f "$new_path/settings.json" ]] || [[ -d "$new_path/database" ]]; then
                log_success "$service: Found config files"
            else
                log_warning "$service: Config files not found"
            fi
            ;;
    esac
    
    log_success "$service: Verification complete ($file_count files)"
    return 0
}

# =============================================================================
# MAIN MIGRATION PROCESS
# =============================================================================

# Create backup directory
BACKUP_DIR="${REPO_ROOT}/migration-backup-$(date +%Y%m%d-%H%M%S)"
if [[ "$SKIP_BACKUP" == false ]]; then
    mkdir -p "$BACKUP_DIR"
    log_info "Backup directory: $BACKUP_DIR"
fi

# Test connectivity
if [[ -n "$OLD_VM_IP" ]]; then
    log_info "Testing connection to old VM ($OLD_VM_IP)..."
    if ! run_remote "echo 'Connection test'" &>/dev/null; then
        log_error "Cannot connect to old VM. Check IP, SSH key, and network connectivity."
        exit 1
    fi
    log_success "Connected to old VM"
    
    # Check if Docker is available on old VM
    if ! run_remote "command -v docker" &>/dev/null; then
        log_warning "Docker not found on old VM. Will try to find volumes manually."
    fi
fi

echo ""
log_info "Starting migration process..."
echo ""

# Track migration results
MIGRATED=()
FAILED=()
SKIPPED=()

# Migrate each service
for service in "${!SERVICE_PATHS[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Service: $service"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Find old volume path
    old_path=""
    
    # Try container name first
    if [[ -n "$OLD_VM_IP" ]]; then
        old_path=$(find_old_volume "$service" "$service")
    fi
    
    # If not found, try with _data suffix
    if [[ -z "$old_path" ]]; then
        old_path=$(find_old_volume "$service" "${service}_data")
    fi
    
    # If still not found and OLD_VM_PATH is set, use it
    if [[ -z "$old_path" && -n "$OLD_VM_PATH" ]]; then
        if [[ -d "$OLD_VM_PATH/$service" ]]; then
            old_path="$OLD_VM_PATH/$service"
        elif [[ -d "$OLD_VM_PATH/${service}_data" ]]; then
            old_path="$OLD_VM_PATH/${service}_data"
        fi
    fi
    
    if [[ -z "$old_path" ]]; then
        log_warning "Could not find volume path for $service"
        SKIPPED+=("$service")
        echo ""
        continue
    fi
    
    # Verify old path exists and has content
    if [[ -n "$OLD_VM_IP" ]]; then
        if ! run_remote "test -d $old_path && [ \$(find $old_path -type f | wc -l) -gt 0 ]" 2>/dev/null; then
            log_warning "$service: Old path exists but appears empty: $old_path"
            SKIPPED+=("$service")
            echo ""
            continue
        fi
    else
        if [[ ! -d "$old_path" ]] || [[ $(find "$old_path" -type f | wc -l) -eq 0 ]]; then
            log_warning "$service: Old path exists but appears empty: $old_path"
            SKIPPED+=("$service")
            echo ""
            continue
        fi
    fi
    
    # Set new path
    new_path="$NEW_BASE_PATH/$service"
    
    # Special handling for tdarr (has multiple subdirectories)
    if [[ "$service" == "tdarr" ]]; then
        # Tdarr has server, configs, logs subdirectories
        for subdir in server configs logs; do
            sub_old_path="$old_path/$subdir"
            sub_new_path="$NEW_BASE_PATH/tdarr/$subdir"
            
            if [[ -n "$OLD_VM_IP" ]]; then
                if run_remote "test -d $sub_old_path" 2>/dev/null; then
                    if [[ "$SKIP_BACKUP" == false ]]; then
                        backup_service "${service}_${subdir}" "$sub_old_path" "$BACKUP_DIR"
                    fi
                    migrate_service "${service}_${subdir}" "$sub_old_path" "$sub_new_path"
                    verify_service "${service}_${subdir}" "$sub_new_path"
                fi
            else
                if [[ -d "$sub_old_path" ]]; then
                    if [[ "$SKIP_BACKUP" == false ]]; then
                        backup_service "${service}_${subdir}" "$sub_old_path" "$BACKUP_DIR"
                    fi
                    migrate_service "${service}_${subdir}" "$sub_old_path" "$sub_new_path"
                    verify_service "${service}_${subdir}" "$sub_new_path"
                fi
            fi
        done
        # Also handle tdarr-cache
        if [[ -d "$old_path/../tdarr-cache" ]] || run_remote "test -d ${old_path%/*}/tdarr-cache" 2>/dev/null; then
            cache_old_path="${old_path%/*}/tdarr-cache"
            cache_new_path="$NEW_BASE_PATH/tdarr-cache"
            if [[ "$SKIP_BACKUP" == false ]]; then
                backup_service "tdarr-cache" "$cache_old_path" "$BACKUP_DIR"
            fi
            migrate_service "tdarr-cache" "$cache_old_path" "$cache_new_path"
        fi
        MIGRATED+=("$service")
    else
        # Standard service migration
        if [[ "$SKIP_BACKUP" == false ]]; then
            if ! backup_service "$service" "$old_path" "$BACKUP_DIR"; then
                log_error "Backup failed for $service, skipping migration"
                FAILED+=("$service")
                echo ""
                continue
            fi
        fi
        
        if migrate_service "$service" "$old_path" "$new_path"; then
            if verify_service "$service" "$new_path"; then
                MIGRATED+=("$service")
            else
                log_warning "$service: Migration completed but verification had warnings"
                MIGRATED+=("$service")
            fi
        else
            FAILED+=("$service")
        fi
    fi
    
    echo ""
done

# =============================================================================
# SUMMARY
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Migration Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ ${#MIGRATED[@]} -gt 0 ]]; then
    log_success "Successfully migrated (${#MIGRATED[@]}): ${MIGRATED[*]}"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    log_error "Failed (${#FAILED[@]}): ${FAILED[*]}"
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    log_warning "Skipped (${#SKIPPED[@]}): ${SKIPPED[*]}"
fi

echo ""
if [[ "$SKIP_BACKUP" == false ]]; then
    echo "Backups saved to: $BACKUP_DIR"
    echo ""
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "⚠️  This was a dry run. No changes were made."
    echo "Run without --dry-run to perform the actual migration."
else
    echo "Next steps:"
    echo "1. Review the migrated data in: $NEW_BASE_PATH"
    echo "2. Start your new Docker stack:"
    echo "   cd $NEW_STACK_PATH"
    echo "   docker compose up -d"
    echo "3. Verify services are working correctly"
    echo "4. Keep backups for at least 2 weeks before removing"
fi

echo ""


