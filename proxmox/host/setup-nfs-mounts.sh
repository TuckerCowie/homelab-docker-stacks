#!/bin/bash
# =============================================================================
# Proxmox Host NFS Mount Configuration
# =============================================================================
# This script configures NFS mounts from Synology NAS on the Proxmox host.
# LXCs will then bind-mount from these paths for optimal performance.
#
# Run this script on the Proxmox host as root.
# =============================================================================

set -euo pipefail

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    # Temporarily disable -u to allow unset variables during sourcing
    set +u
    source "$ENV_FILE"
    set -u
else
    echo "ERROR: .env file not found at $ENV_FILE"
    echo "Copy .env.example to .env and configure before running."
    exit 1
fi

# Validate required variables
: "${SYNOLOGY_LAN_IP:?SYNOLOGY_LAN_IP must be set in .env}"
: "${SYNOLOGY_MEDIA_EXPORT:?SYNOLOGY_MEDIA_EXPORT must be set in .env}"
: "${SYNOLOGY_TORRENTS_EXPORT:?SYNOLOGY_TORRENTS_EXPORT must be set in .env}"
: "${SYNOLOGY_DOCKER_DATA_EXPORT:?SYNOLOGY_DOCKER_DATA_EXPORT must be set in .env}"
: "${SYNOLOGY_BACKUPS_EXPORT:?SYNOLOGY_BACKUPS_EXPORT must be set in .env}"

# =============================================================================
# INSTALL NFS CLIENT
# =============================================================================
echo "Installing NFS client packages..."
apt-get update
apt-get install -y nfs-common

# =============================================================================
# CREATE MOUNT POINTS
# =============================================================================
echo "Creating mount point directories..."
mkdir -p /mnt/synology/{media,torrents,docker-data,backups} # frigate is not yet mounted on the host

# =============================================================================
# CONFIGURE /etc/fstab
# =============================================================================
# NFS mount options optimized for media streaming and Docker workloads:
#   - nfsvers=4.1: Modern NFS with better performance
#   - hard: Retry indefinitely on server failure (safer for data)
#   - intr: Allow interrupts during hangs
#   - rsize/wsize=1048576: 1MB read/write buffers for throughput
#   - timeo=600: 60 second timeout
#   - retrans=2: Retry twice before reporting error
#   - _netdev: Wait for network before mounting
#   - nofail: Don't block boot if mount fails

FSTAB_ENTRIES=(
    "${SYNOLOGY_LAN_IP}:${SYNOLOGY_MEDIA_EXPORT} /mnt/synology/media nfs4 nfsvers=4.1,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2,_netdev,nofail 0 0"
    "${SYNOLOGY_LAN_IP}:${SYNOLOGY_TORRENTS_EXPORT} /mnt/synology/torrents nfs4 nfsvers=4.1,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2,_netdev,nofail 0 0"
    "${SYNOLOGY_LAN_IP}:${SYNOLOGY_DOCKER_DATA_EXPORT} /mnt/synology/docker-data nfs4 nfsvers=4.1,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2,_netdev,nofail 0 0"
    "${SYNOLOGY_LAN_IP}:${SYNOLOGY_BACKUPS_EXPORT} /mnt/synology/backups nfs4 nfsvers=4.1,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2,_netdev,nofail 0 0"
    # "${SYNOLOGY_LAN_IP}:${SYNOLOGY_FRIGATE_EXPORT} /mnt/synology/frigate nfs4 nfsvers=4.1,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2,_netdev,nofail 0 0"
)

echo "Configuring /etc/fstab..."
FSTAB_BACKUP="/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
cp /etc/fstab "$FSTAB_BACKUP"
echo "Backed up fstab to $FSTAB_BACKUP"

# Add marker comments
if ! grep -q "# SYNOLOGY NFS MOUNTS" /etc/fstab; then
    echo "" >> /etc/fstab
    echo "# SYNOLOGY NFS MOUNTS - Managed by homelab-infrastructure" >> /etc/fstab
fi

for entry in "${FSTAB_ENTRIES[@]}"; do
    mount_point=$(echo "$entry" | awk '{print $2}')
    if ! grep -q "$mount_point" /etc/fstab; then
        echo "$entry" >> /etc/fstab
        echo "Added fstab entry for $mount_point"
    else
        echo "Entry for $mount_point already exists, skipping"
    fi
done

# =============================================================================
# MOUNT ALL
# =============================================================================
echo "Mounting all NFS shares..."
mount -a

# Verify mounts
echo ""
echo "=== Verifying NFS mounts ==="
for mount_point in /mnt/synology/media /mnt/synology/torrents /mnt/synology/docker-data /mnt/synology/backups /mnt/synology/frigate; do
    if mountpoint -q "$mount_point"; then
        echo "✓ $mount_point is mounted"
        df -h "$mount_point" | tail -1
    else
        echo "✗ $mount_point is NOT mounted"
    fi
done

echo ""
echo "=== NFS mount configuration complete ==="
echo ""
echo "Next steps:"
echo "1. Verify permissions: ls -la /mnt/synology/"
echo "2. Create LXCs that bind-mount from these paths"
echo "3. Ensure Synology NFS permissions allow access from Proxmox IP"
