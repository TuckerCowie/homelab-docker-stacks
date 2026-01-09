#!/bin/bash
# =============================================================================
# Jellyfin LXC Creation Script
# =============================================================================
# Creates an unprivileged LXC container with Intel iGPU passthrough for
# hardware-accelerated transcoding via Quick Sync Video (QSV).
#
# Run this script on the Proxmox host as root.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
# Load environment FIRST before using any variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../.env"  # Path to repo root .env file

if [[ -f "$ENV_FILE" ]]; then
    # Temporarily disable -u to allow unset variables during sourcing
    set +u
    source "$ENV_FILE"
    set -u
else
    echo "WARNING: .env file not found at $ENV_FILE"
    echo "Using defaults or environment variables"
fi

CTID="${CTID:-102}"                          # Container ID
HOSTNAME=jellyfin
TEMPLATE="${TEMPLATE:-local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
STORAGE="${STORAGE:-local-lvm}"
ROOTFS_SIZE="${ROOTFS_SIZE:-64}"              # GB
MEMORY="${MEMORY:-4096}"                     # MB
SWAP="${SWAP:-512}"                          # MB
CORES="${CORES:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
STATIC_IP="${JELLYFIN_LXC_IP:-dhcp}"
GATEWAY="${GATEWAY:-192.168.1.1}"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
echo "=== Pre-flight checks ==="

# Check if container already exists
if pct status "$CTID" &>/dev/null; then
    echo "ERROR: Container $CTID already exists"
    exit 1
fi

# Check for template
if ! pveam list local | grep -q "ubuntu-24.04"; then
    echo "Downloading Ubuntu 22.04 template..."
    pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
fi

# Verify iGPU is available
if [[ ! -e /dev/dri/renderD128 ]]; then
    echo "ERROR: /dev/dri/renderD128 not found. Ensure Intel iGPU is available."
    echo "Check: ls -la /dev/dri/"
    exit 1
fi

# Get render group GID
RENDER_GID=$(getent group render | cut -d: -f3)
VIDEO_GID=$(getent group video | cut -d: -f3)
echo "Host render GID: $RENDER_GID"
echo "Host video GID: $VIDEO_GID"

# =============================================================================
# CREATE CONTAINER
# =============================================================================
echo ""
echo "=== Creating LXC container $CTID ($HOSTNAME) ==="

# Network configuration
if [[ "$STATIC_IP" == "dhcp" ]]; then
    NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp"
else
    NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=${STATIC_IP}/24,gw=${GATEWAY}"
fi

pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${ROOTFS_SIZE}" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --cores "$CORES" \
    --net0 "$NET_CONFIG" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0

echo "Container created successfully"

# =============================================================================
# CONFIGURE GPU PASSTHROUGH
# =============================================================================
echo ""
echo "=== Configuring iGPU passthrough ==="

# LXC config file
LXC_CONF="/etc/pve/lxc/${CTID}.conf"

# Add GPU device passthrough
cat >> "$LXC_CONF" << EOF

# Intel iGPU passthrough for Jellyfin QSV transcoding
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file

# ID mapping for render group access
# Map container's render group (104) to host's render group ($RENDER_GID)
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 44
lxc.idmap: g 44 44 1
lxc.idmap: g 45 100045 54
lxc.idmap: g 99 ${RENDER_GID} 1
lxc.idmap: g 100 100100 65436
EOF

# Create subuid/subgid mappings on host
echo "Configuring host UID/GID mappings..."
if ! grep -q "root:${RENDER_GID}:1" /etc/subgid; then
    echo "root:${RENDER_GID}:1" >> /etc/subgid
fi
if ! grep -q "root:44:1" /etc/subgid; then
    echo "root:44:1" >> /etc/subgid
fi

echo "GPU passthrough configured"

# =============================================================================
# ADD NFS BIND MOUNTS
# =============================================================================
echo ""
echo "=== Configuring bind mounts ==="

# Verify NFS mounts exist on host before creating bind mounts
MEDIA_MOUNT=${NFS_MEDIA_PATH}
CONFIG_MOUNT=${NFS_DOCKER_DATA_PATH}/jellyfin

echo "Verifying host NFS mounts..."
if mountpoint -q "$MEDIA_MOUNT" 2>/dev/null; then
    echo "✓ $MEDIA_MOUNT is mounted on host"
    echo "  Content check: $(ls -1 "$MEDIA_MOUNT" 2>/dev/null | wc -l) items"
else
    echo "⚠ $MEDIA_MOUNT is NOT mounted on host"
    echo "  Attempting to mount..."
    mount "$MEDIA_MOUNT" 2>/dev/null || {
        echo "  ERROR: Cannot mount $MEDIA_MOUNT"
        echo "  Please run: /host/setup-nfs-mounts.sh first"
        echo "  Or manually mount: mount -a"
    }
fi

# Create config directory on NAS if it doesn't exist
mkdir -p "$CONFIG_MOUNT"

# Set initial permissions on host (will be adjusted after container creation)
# For unprivileged containers, UID 1000 in container maps to 101000 on host
# We'll set proper ownership after Jellyfin user is created
chmod 755 "$CONFIG_MOUNT"

# Add bind mounts to LXC config
cat >> "$LXC_CONF" << EOF

# Bind mounts from Proxmox host NFS mounts
mp0: ${MEDIA_MOUNT},mp=/media,ro=0
mp1: ${CONFIG_MOUNT},mp=/config,ro=0
EOF

echo "Bind mounts configured:"
echo "  Host: $MEDIA_MOUNT -> Container: /media"
echo "  Host: $CONFIG_MOUNT -> Container: /config"

# =============================================================================
# START AND CONFIGURE CONTAINER
# =============================================================================
echo ""
echo "=== Starting container and installing Jellyfin ==="

pct start "$CTID"
sleep 5  # Wait for container to fully start

# Update and install Jellyfin
pct exec "$CTID" -- bash -c "
    set -e
    
    # Update system first
    apt-get update
    apt-get install -y curl gnupg apt-transport-https ca-certificates
    
    # Detect Ubuntu version and set repository codename
    UBUNTU_VERSION=\$(lsb_release -cs)
    echo \"Detected Ubuntu version: \$UBUNTU_VERSION\"
    
    # Map Ubuntu versions to Jellyfin repository codenames
    # Ubuntu 24.04 (Noble) -> try noble, fallback to jammy if not available
    # Ubuntu 22.04 (Jammy) -> use jammy repository
    # Fallback to jammy for older versions
    case \"\$UBUNTU_VERSION\" in
        noble)
            # Try noble first, but it may not exist yet
            JELLYFIN_CODENAME=\"noble\"
            ;;
        jammy)
            JELLYFIN_CODENAME=\"jammy\"
            ;;
        *)
            echo \"WARNING: Ubuntu version \$UBUNTU_VERSION not explicitly supported\"
            echo \"Attempting to use jammy repository (may not work)\"
            JELLYFIN_CODENAME=\"jammy\"
            ;;
    esac
    
    echo \"Using Jellyfin repository: \$JELLYFIN_CODENAME\"
    
    # Add Jellyfin repository
    curl -fsSL https://repo.jellyfin.org/ubuntu/jellyfin_team.gpg.key | gpg --dearmor -o /usr/share/keyrings/jellyfin-archive-keyring.gpg
    echo \"deb [signed-by=/usr/share/keyrings/jellyfin-archive-keyring.gpg] https://repo.jellyfin.org/ubuntu \$JELLYFIN_CODENAME main\" > /etc/apt/sources.list.d/jellyfin.list
    
    apt-get update
    
    # Check if repository is accessible, fallback to jammy if noble doesn't work
    if ! apt-cache show jellyfin-server &>/dev/null && [[ \"\$JELLYFIN_CODENAME\" == \"noble\" ]]; then
        echo \"WARNING: Noble repository not available, falling back to jammy\"
        JELLYFIN_CODENAME=\"jammy\"
        echo \"deb [signed-by=/usr/share/keyrings/jellyfin-archive-keyring.gpg] https://repo.jellyfin.org/ubuntu \$JELLYFIN_CODENAME main\" > /etc/apt/sources.list.d/jellyfin.list
        apt-get update
    fi
    
    # Note: Dependencies will be handled by apt when installing Jellyfin
    # If there are issues, they're likely due to repository/version mismatches
    
    # Try installing jellyfin-ffmpeg7 first (newer), fall back to ffmpeg6 if needed
    echo \"Installing Jellyfin packages...\"
    INSTALL_SUCCESS=0
    
    if apt-get install -y jellyfin-server jellyfin-ffmpeg7 2>&1 | tee /tmp/jellyfin-install.log; then
        echo \"✓ Installed jellyfin-server and jellyfin-ffmpeg7\"
        INSTALL_SUCCESS=1
    elif apt-get install -y jellyfin-server jellyfin-ffmpeg6 2>&1 | tee /tmp/jellyfin-install.log; then
        echo \"✓ Installed jellyfin-server and jellyfin-ffmpeg6\"
        INSTALL_SUCCESS=1
    fi
    
    if [[ \$INSTALL_SUCCESS -eq 0 ]]; then
        echo \"ERROR: Failed to install Jellyfin packages\"
        echo \"Installation log:\"
        cat /tmp/jellyfin-install.log | tail -30
        echo \"\"
        echo \"Attempting to install with --fix-broken...\"
        apt-get install -f -y || true
        apt-get install -y jellyfin-server jellyfin-ffmpeg6 || {
            echo \"ERROR: Jellyfin installation failed after dependency fixes.\"
            echo \"You may need to:\"
            echo \"  1. Check if Ubuntu 24.04 is fully supported by Jellyfin\"
            echo \"  2. Consider using Ubuntu 22.04 template instead\"
            echo \"  3. Install dependencies manually\"
            exit 1
        }
    fi
    
    # Verify jellyfin user was created
    if ! id jellyfin &>/dev/null; then
        echo \"ERROR: jellyfin user was not created during package installation\"
        exit 1
    fi
    
    # Add jellyfin user to render and video groups for GPU access
    usermod -aG render jellyfin
    usermod -aG video jellyfin
    echo \"✓ Added jellyfin user to render and video groups\"
    
    # Configure Jellyfin to use /config
    # Note: /config is a bind mount, so we need to handle ownership carefully
    mkdir -p /config
    
    # Get jellyfin user UID/GID in container
    JELLYFIN_UID=\$(id -u jellyfin)
    JELLYFIN_GID=\$(id -g jellyfin)
    echo \"Jellyfin user UID in container: \$JELLYFIN_UID, GID: \$JELLYFIN_GID\"
    
    # For unprivileged containers, we can't chown bind mounts directly
    # Instead, set permissions that allow access, or use setfacl if available
    # The host-side ownership will be set after container setup
    chmod 755 /config || true
    
    # Try to set ownership (may fail for bind mounts, that's OK)
    chown -R jellyfin:jellyfin /config 2>/dev/null || {
        echo \"Note: Could not change ownership of /config (bind mount limitation)\"
        echo \"Will set ownership on host side instead\"
    }
    
    echo \"✓ Configured /config directory\"
    
    # Update Jellyfin service to use custom config path
    mkdir -p /etc/systemd/system/jellyfin.service.d
    cat > /etc/systemd/system/jellyfin.service.d/override.conf << 'OVERRIDE'
[Service]
Environment=\"JELLYFIN_DATA_DIR=/config/data\"
Environment=\"JELLYFIN_CONFIG_DIR=/config/config\"
Environment=\"JELLYFIN_CACHE_DIR=/config/cache\"
Environment=\"JELLYFIN_LOG_DIR=/config/log\"
OVERRIDE
    
    systemctl daemon-reload
    
    # Enable and start Jellyfin service
    if systemctl enable jellyfin; then
        echo \"✓ Jellyfin service enabled\"
    else
        echo \"WARNING: Failed to enable Jellyfin service\"
    fi
    
    if systemctl start jellyfin; then
        echo \"✓ Jellyfin service started\"
    else
        echo \"WARNING: Failed to start Jellyfin service (may need manual start)\"
        systemctl status jellyfin || true
    fi
    
    echo 'Jellyfin installation complete'
"

# =============================================================================
# SET HOST-SIDE OWNERSHIP FOR BIND MOUNTS
# =============================================================================
echo ""
echo "=== Setting ownership on host-side bind mounts ==="

# Get jellyfin user UID/GID from container
JELLYFIN_UID_CONTAINER=$(pct exec "$CTID" -- id -u jellyfin 2>/dev/null || echo "1000")
JELLYFIN_GID_CONTAINER=$(pct exec "$CTID" -- id -g jellyfin 2>/dev/null || echo "1000")

# For unprivileged containers, UID mapping is: container_uid + 100000 = host_uid
JELLYFIN_UID_HOST=$((JELLYFIN_UID_CONTAINER + 100000))
JELLYFIN_GID_HOST=$((JELLYFIN_GID_CONTAINER + 100000))

echo "Jellyfin UID in container: $JELLYFIN_UID_CONTAINER -> Host UID: $JELLYFIN_UID_HOST"
echo "Jellyfin GID in container: $JELLYFIN_GID_CONTAINER -> Host GID: $JELLYFIN_GID_HOST"

# Set ownership on host-side bind mount directory
if [[ -d /mnt/synology/docker-data/jellyfin ]]; then
    # Check if the mapped UID/GID exist on host, if not create them or use existing
    if ! getent passwd "$JELLYFIN_UID_HOST" &>/dev/null; then
        echo "Creating host user mapping for jellyfin (UID $JELLYFIN_UID_HOST)..."
        # We can't easily create the user, so we'll use chown with numeric UID
    fi
    
    chown -R "${JELLYFIN_UID_HOST}:${JELLYFIN_GID_HOST}" /mnt/synology/docker-data/jellyfin 2>/dev/null && \
        echo "✓ Set ownership on /mnt/synology/docker-data/jellyfin" || {
        echo "⚠ Could not set ownership (may need to run manually):"
        echo "  chown -R ${JELLYFIN_UID_HOST}:${JELLYFIN_GID_HOST} /mnt/synology/docker-data/jellyfin"
    }
else
    echo "⚠ Bind mount directory not found on host"
fi

# =============================================================================
# VERIFY BIND MOUNTS
# =============================================================================
echo ""
echo "=== Verifying bind mounts ==="

# Check if host NFS mount exists and is mounted
if mountpoint -q /mnt/synology/media; then
    echo "✓ Host NFS mount /mnt/synology/media is mounted"
    echo "  Content preview:"
    ls -la /mnt/synology/media | head -5 || echo "  (directory may be empty or have permission issues)"
else
    echo "✗ Host NFS mount /mnt/synology/media is NOT mounted"
    echo "  Run: mount -a or check /etc/fstab"
fi

# Verify bind mount inside container
pct exec "$CTID" -- bash -c "
    echo 'Checking bind mounts inside container...'
    
    # Check if /media exists and is mounted
    if mountpoint -q /media 2>/dev/null; then
        echo '✓ /media is mounted (bind mount working)'
        echo '  Mount details:'
        mount | grep ' /media ' || true
        echo ''
        echo '  Content preview:'
        ls -la /media | head -10 || {
            echo '  ⚠ Cannot list /media contents - checking permissions...'
            stat /media || true
        }
    else
        echo '✗ /media is NOT mounted (bind mount failed)'
        echo '  Checking if directory exists:'
        ls -ld /media 2>/dev/null || echo '  /media does not exist'
    fi
    
    # Check /config mount
    if mountpoint -q /config 2>/dev/null; then
        echo '✓ /config is mounted'
    else
        echo '⚠ /config may not be mounted (check bind mount config)'
    fi
"

# =============================================================================
# VERIFY GPU ACCESS
# =============================================================================
echo ""
echo "=== Verifying GPU access ==="

pct exec "$CTID" -- bash -c "
    if [[ -e /dev/dri/renderD128 ]]; then
        echo '✓ /dev/dri/renderD128 is accessible'
        ls -la /dev/dri/
    else
        echo '✗ GPU not accessible - check passthrough config'
    fi
"

# =============================================================================
# SUMMARY
# =============================================================================
CONTAINER_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo ""
echo "=========================================="
echo "Jellyfin LXC Setup Complete!"
echo "=========================================="
echo ""
echo "Container ID:  $CTID"
echo "Hostname:      $HOSTNAME"
echo "IP Address:    $CONTAINER_IP"
echo "Jellyfin URL:  http://${CONTAINER_IP}:8096"
echo ""
echo "Configuration: /mnt/synology/docker-data/jellyfin"
echo "Media Library: /media (inside container)"
echo ""
echo "Next steps:"
echo "1. Verify /config ownership (if Jellyfin can't write, run manually):"
echo "   chown -R ${JELLYFIN_UID_HOST}:${JELLYFIN_GID_HOST} /mnt/synology/docker-data/jellyfin"
echo ""
echo "2. Verify bind mounts are working:"
echo "   pct exec $CTID -- ls -la /media"
echo "   pct exec $CTID -- mountpoint /media"
echo ""
echo "3. If /media is empty or not accessible:"
echo "   - Verify host mount: mountpoint /mnt/synology/media"
echo "   - Check host content: ls -la /mnt/synology/media"
echo "   - Restart container: pct stop $CTID && pct start $CTID"
echo "   - Check container logs: journalctl -u pve-container@$CTID"
echo ""
echo "4. Access Jellyfin at http://${CONTAINER_IP}:8096"
echo "5. Complete initial setup wizard"
echo "6. Add media libraries pointing to /media"
echo "7. Enable hardware acceleration in Dashboard > Playback"
echo "   - Select 'Intel QuickSync (QSV)'"
echo "8. Configure Tailscale access (see docs)"
echo ""
