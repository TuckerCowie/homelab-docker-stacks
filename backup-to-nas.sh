#!/bin/bash
#
# Docker Stacks Backup to NAS
# 
# This script backs up all Docker stack data directories to a Synology NAS
# via NFS. It uses rsync for efficient incremental backups.
#
# Setup Instructions:
# 1. Copy this file to /opt/stacks/backup-to-nas.sh
# 2. Make executable: chmod +x /opt/stacks/backup-to-nas.sh
# 3. Configure NFS mount point and stacks directory below
# 4. Test manually: /opt/stacks/backup-to-nas.sh
# 5. Add to crontab: 
#    (crontab -l; echo "0 2 * * * /opt/stacks/backup-to-nas.sh >> /var/log/nas-backup.log 2>&1") | crontab -
#
# This will run daily at 2 AM and log to /var/log/nas-backup.log

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# NFS mount point for backups
NFS_BACKUP="/mnt/synology-backup"

# Source directory containing all stacks
STACKS="/opt/stacks"

# NFS server details (only used if auto-mount is enabled)
NFS_SERVER="100.98.188.126"
NFS_EXPORT="/volume1/Backups"

# Rsync options
RSYNC_OPTS="-av --delete --exclude='.git' --exclude='*.log'"

# Enable logging
LOG_FILE="/var/log/nas-backup.log"

# ============================================================================
# Functions
# ============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

check_nfs_mount() {
    if ! mountpoint -q "$NFS_BACKUP"; then
        log "NFS not mounted at $NFS_BACKUP, attempting to mount..."
        
        # Create mount point if it doesn't exist
        if [ ! -d "$NFS_BACKUP" ]; then
            mkdir -p "$NFS_BACKUP"
        fi
        
        # Try to mount
        if mount -t nfs4 "${NFS_SERVER}:${NFS_EXPORT}" "$NFS_BACKUP"; then
            log "Successfully mounted NFS"
        else
            error "Failed to mount NFS. Backup aborted."
            exit 1
        fi
    else
        log "NFS already mounted at $NFS_BACKUP"
    fi
}

backup_stack() {
    local stack_name=$1
    local source_dir="${STACKS}/${stack_name}/data"
    local dest_dir="${NFS_BACKUP}/${stack_name}"
    
    if [ ! -d "$source_dir" ]; then
        log "Skipping ${stack_name}: source directory not found"
        return
    fi
    
    log "Backing up ${stack_name}..."
    
    # Create destination directory if it doesn't exist
    mkdir -p "$dest_dir"
    
    # Perform backup
    if rsync $RSYNC_OPTS "$source_dir/" "$dest_dir/"; then
        log "Successfully backed up ${stack_name}"
    else
        error "Failed to backup ${stack_name}"
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

log "=== Backup job started ==="

# Check NFS mount
check_nfs_mount

# Backup each stack
backup_stack "tandoor"
backup_stack "comfyui"
backup_stack "media"

# Backup compose files and configs (excluding .env for security)
log "Backing up compose files..."
for stack_dir in "$STACKS"/*; do
    if [ -d "$stack_dir" ]; then
        stack_name=$(basename "$stack_dir")
        dest_dir="${NFS_BACKUP}/${stack_name}"
        
        # Backup docker-compose.yml
        if [ -f "${stack_dir}/docker-compose.yml" ]; then
            rsync -av "${stack_dir}/docker-compose.yml" "${dest_dir}/"
        fi
        
        # Backup nginx.conf if it exists
        if [ -f "${stack_dir}/nginx.conf" ]; then
            rsync -av "${stack_dir}/nginx.conf" "${dest_dir}/"
        fi
        
        # Backup .env.template (NOT .env - that has secrets!)
        if [ -f "${stack_dir}/.env.template" ]; then
            rsync -av "${stack_dir}/.env.template" "${dest_dir}/"
        fi
    fi
done

# Calculate backup size
backup_size=$(du -sh "$NFS_BACKUP" 2>/dev/null | cut -f1)
log "Total backup size: ${backup_size}"

log "=== Backup job completed successfully ==="

exit 0
