#!/bin/bash
# =============================================================================
# Docker VM Creation Script
# =============================================================================
# Creates a Linux VM for running Docker with:
# - Arr stack (Sonarr, Radarr, Prowlarr, qBittorrent)
# - Tandoor Recipes
# - Support services (Bazarr, Jellyseerr, Tdarr, etc.)
#
# Uses cloud-init for automated Ubuntu installation and configuration.
# Run this script on the Proxmox host as root.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
# Load environment FIRST before using any variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"  # Path to repo root .env file

if [[ -f "$ENV_FILE" ]]; then
    # Temporarily disable -u to allow unset variables during sourcing
    set +u
    source "$ENV_FILE"
    set -u
else
    echo "WARNING: .env file not found at $ENV_FILE"
    echo "Using defaults or environment variables"
fi

VMID="${VMID:-103}"                             # VM ID
HOSTNAME=docker
ISO_STORAGE="${ISO_STORAGE:-local}"              # Storage for ISO files
STORAGE="${STORAGE:-local-lvm}"                  # Storage for VM disk
DISK_SIZE="${DISK_SIZE:-45}"                     # GB - Docker needs more space
MEMORY="${MEMORY:-4096}"                         # MB
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
STATIC_IP="${DOCKER_LXC_IP:-dhcp}"
GATEWAY="${GATEWAY:-192.168.1.1}"
NETMASK="${NETMASK:-24}"
DNS_SERVERS="${DNS_SERVERS:-192.168.1.1}"

# NFS Configuration (for mounting Synology NAS)
NFS_SERVER="${SYNOLOGY_LAN_IP:-}"        # Synology NAS IP
NFS_MEDIA="${SYNOLOGY_MEDIA_EXPORT:-}"
NFS_TORRENTS="${SYNOLOGY_TORRENTS_EXPORT:-}"
NFS_DOCKER_DATA="${SYNOLOGY_DOCKER_DATA_EXPORT:-}"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
echo "=== Pre-flight checks ==="

# Check if VM already exists
if qm status "$VMID" &>/dev/null; then
    echo "ERROR: VM $VMID already exists"
    exit 1
fi

# Check for Ubuntu ISO
UBUNTU_ISO="ubuntu-24.04.3-live-server-amd64.iso"

echo "Checking for Ubuntu ISO in storage '$ISO_STORAGE'..."

# Try multiple methods to find the ISO
FOUND_ISO=""

# Method 1: Check via pveam list
ISO_LIST=$(pveam list "$ISO_STORAGE" 2>/dev/null || echo "")
if [[ -n "$ISO_LIST" ]]; then
    echo "Available ISOs in storage:"
    echo "$ISO_LIST" | grep -i "iso" || echo "  (none found via pveam)"
    
    # Check for exact match
    if echo "$ISO_LIST" | grep -qi "$UBUNTU_ISO"; then
        FOUND_ISO="$UBUNTU_ISO"
    # Check for any Ubuntu 24.04 ISO
    elif echo "$ISO_LIST" | grep -qiE "ubuntu.*24\.04.*\.iso"; then
        # Extract filename (handle both "iso/filename" and just "filename" formats)
        FOUND_ISO=$(echo "$ISO_LIST" | grep -iE "ubuntu.*24\.04.*\.iso" | head -1 | sed -E 's|.*iso/||; s|.*/||' | awk '{print $1}' | tr -d '\r\n')
    fi
fi

# Method 2: Check filesystem directly (for local storage)
if [[ -z "$FOUND_ISO" && "$ISO_STORAGE" == "local" ]]; then
    ISO_DIR="/var/lib/vz/template/iso"
    if [[ -d "$ISO_DIR" ]]; then
        # Check for exact match
        if [[ -f "${ISO_DIR}/${UBUNTU_ISO}" ]]; then
            FOUND_ISO="$UBUNTU_ISO"
        # Check for any Ubuntu 24.04 ISO
        elif ls "${ISO_DIR}"/ubuntu*24.04*.iso 2>/dev/null | head -1 | read -r found_file; then
            FOUND_ISO=$(basename "$found_file")
        fi
    fi
fi

if [[ -n "$FOUND_ISO" ]]; then
    UBUNTU_ISO="$FOUND_ISO"
    echo "✓ Found Ubuntu ISO: $UBUNTU_ISO"
else
    echo ""
    echo "ERROR: Ubuntu 24.04 ISO not found in storage '$ISO_STORAGE'"
    echo ""
    echo "Please download Ubuntu 24.04.3 Server ISO and upload it to Proxmox:"
    echo "  - Download from: https://releases.ubuntu.com/24.04.3/"
    echo "  - Upload via Proxmox web UI: Datacenter > $ISO_STORAGE > Content > Upload"
    echo "  - Or use: pveam download $ISO_STORAGE $UBUNTU_ISO https://releases.ubuntu.com/24.04.3/ubuntu-24.04.3-live-server-amd64.iso"
    echo ""
    exit 1
fi

# =============================================================================
# CREATE CLOUD-INIT CONFIG
# =============================================================================
echo ""
echo "=== Creating cloud-init configuration ==="

CLOUD_INIT_DIR="/tmp/cloud-init-${VMID}"
mkdir -p "$CLOUD_INIT_DIR"

# Generate SSH key if not exists
SSH_KEY_FILE="${SCRIPT_DIR}/id_rsa_docker_vm"
if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "Generating SSH key for VM access..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_FILE" -N "" -C "docker-vm-${VMID}"
fi

PUBLIC_KEY=$(cat "${SSH_KEY_FILE}.pub")

# Create user-data with autoinstall configuration
# For Ubuntu Server 24.04, autoinstall is the primary format for automated installation
# Note: The #cloud-config header is kept for compatibility, but autoinstall is the key section
cat > "$CLOUD_INIT_DIR/user-data" << EOF
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: ${HOSTNAME}
    username: docker
    password: '\$6\$rounds=4096\$dummy\$dummy'  # SSH key only, password disabled
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - ${PUBLIC_KEY}
  storage:
    layout:
      name: direct
  packages:
    - qemu-guest-agent
    - nfs-common
    - curl
    - wget
    - vim
    - git
    - jq
    - htop
    - iotop
  late-commands:
    - 'echo "docker ALL=(ALL) NOPASSWD:ALL" > /target/etc/sudoers.d/docker'
    - 'chmod 440 /target/etc/sudoers.d/docker'
    - 'usermod -aG docker docker'
    - |
      # Create directory structure
      mkdir -p /target/opt/stacks/{arr-stack,tandoor,support-services}
      mkdir -p /target/mnt/docker-data/{sonarr,radarr,prowlarr,qbittorrent,gluetun}
      mkdir -p /target/mnt/docker-data/{bazarr,jellyseerr,tdarr,tdarr-cache}
      mkdir -p /target/mnt/docker-data/{unpackerr,notifiarr,flaresolverr,profilarr}
      mkdir -p /target/mnt/docker-data/{tandoor,tandoor-db,tandoor-static,tandoor-media}
      chown -R docker:docker /target/opt/stacks
      chown -R docker:docker /target/mnt/docker-data
    - |
      # Setup NFS mounts in fstab
      echo "${NFS_SERVER}:${NFS_MEDIA} /mnt/media nfs defaults,_netdev 0 0" >> /target/etc/fstab
      echo "${NFS_SERVER}:${NFS_TORRENTS} /mnt/torrents nfs defaults,_netdev 0 0" >> /target/etc/fstab
      echo "${NFS_SERVER}:${NFS_DOCKER_DATA} /mnt/docker-data nfs defaults,_netdev 0 0" >> /target/etc/fstab
    - |
      # Create systemd service for NFS mounts
      cat > /target/etc/systemd/system/mount-nfs.service << 'SERVICE_EOF'
      [Unit]
      Description=Mount NFS shares
      After=network-online.target
      Wants=network-online.target
      
      [Service]
      Type=oneshot
      ExecStart=/bin/bash -c 'mount -t nfs ${NFS_SERVER}:${NFS_MEDIA} /mnt/media || true'
      ExecStart=/bin/bash -c 'mount -t nfs ${NFS_SERVER}:${NFS_TORRENTS} /mnt/torrents || true'
      ExecStart=/bin/bash -c 'mount -t nfs ${NFS_SERVER}:${NFS_DOCKER_DATA} /mnt/docker-data || true'
      RemainAfterExit=yes
      
      [Install]
      WantedBy=multi-user.target
      SERVICE_EOF
      chmod 644 /target/etc/systemd/system/mount-nfs.service
    - 'systemctl --root=/target enable mount-nfs.service'
    - |
      # Install Docker (run after first boot via cloud-init)
      cat > /target/etc/cloud/cloud.cfg.d/99-docker-install.cfg << 'CLOUD_EOF'
      #cloud-config
      runcmd:
        - |
          install -m 0755 -d /etc/apt/keyrings
          curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
          chmod a+r /etc/apt/keyrings/docker.gpg
          echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
          apt-get update
          apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
          systemctl enable docker
          systemctl start docker
      final_message: "Docker VM setup complete! User: docker"
      CLOUD_EOF
EOF

# Create meta-data
cat > "$CLOUD_INIT_DIR/meta-data" << EOF
instance-id: ${VMID}
local-hostname: ${HOSTNAME}
EOF

# Create network-config if static IP is specified
if [[ "$STATIC_IP" != "dhcp" ]]; then
    cat > "$CLOUD_INIT_DIR/network-config" << EOF
version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses:
      - ${STATIC_IP}/${NETMASK}
    gateway4: ${GATEWAY}
    nameservers:
      addresses:
        - ${DNS_SERVERS}
EOF
else
    cat > "$CLOUD_INIT_DIR/network-config" << EOF
version: 2
ethernets:
  eth0:
    dhcp4: true
EOF
fi

# Create cloud-init ISO
# The volume label MUST be 'cidata' for Ubuntu to detect it
echo "Creating cloud-init ISO with volume label 'cidata'..."
if command -v genisoimage &> /dev/null; then
    genisoimage -output "/tmp/cloud-init-${VMID}.iso" \
        -volid cidata \
        -joliet \
        -rock \
        "$CLOUD_INIT_DIR/user-data" \
        "$CLOUD_INIT_DIR/meta-data" \
        "$CLOUD_INIT_DIR/network-config"
elif command -v mkisofs &> /dev/null; then
    mkisofs -o "/tmp/cloud-init-${VMID}.iso" \
        -V cidata \
        -J \
        -r \
        "$CLOUD_INIT_DIR/user-data" \
        "$CLOUD_INIT_DIR/meta-data" \
        "$CLOUD_INIT_DIR/network-config"
else
    echo "ERROR: Neither genisoimage nor mkisofs found. Install one of them:"
    echo "  apt-get install genisoimage"
    exit 1
fi

# Verify ISO was created
if [[ ! -f "/tmp/cloud-init-${VMID}.iso" ]]; then
    echo "ERROR: Failed to create cloud-init ISO"
    exit 1
fi

echo "✓ Cloud-init ISO created successfully"

# Copy cloud-init ISO to Proxmox ISO storage
ISO_PATH="/var/lib/vz/template/iso/cloud-init-${VMID}.iso"
if [[ "$ISO_STORAGE" == "local" ]]; then
    cp "/tmp/cloud-init-${VMID}.iso" "$ISO_PATH"
    echo "Cloud-init ISO created at $ISO_PATH"
else
    echo "WARNING: Non-local ISO storage detected. You may need to manually upload the cloud-init ISO."
    echo "ISO location: /tmp/cloud-init-${VMID}.iso"
fi

echo "Cloud-init configuration created"

# =============================================================================
# CREATE VM
# =============================================================================
echo ""
echo "=== Creating VM $VMID ($HOSTNAME) ==="

# Create VM
qm create "$VMID" \
    --name "$HOSTNAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 virtio,bridge=${BRIDGE} \
    --scsihw virtio-scsi-pci \
    --scsi0 "${STORAGE}:${DISK_SIZE},format=raw" \
    --ide2 "${ISO_STORAGE}:iso/${UBUNTU_ISO},media=cdrom" \
    --boot "order=ide2;scsi0" \
    --agent enabled=1 \
    --onboot 1 \
    --ostype l26

# Attach cloud-init ISO
if [[ -f "/var/lib/vz/template/iso/cloud-init-${VMID}.iso" ]]; then
    qm set "$VMID" --ide3 "${ISO_STORAGE}:iso/cloud-init-${VMID}.iso,media=cdrom"
elif [[ -f "/tmp/cloud-init-${VMID}.iso" ]]; then
    # Try to copy to ISO storage
    mkdir -p "/var/lib/vz/template/iso"
    cp "/tmp/cloud-init-${VMID}.iso" "/var/lib/vz/template/iso/"
    qm set "$VMID" --ide3 "${ISO_STORAGE}:iso/cloud-init-${VMID}.iso,media=cdrom"
else
    echo "WARNING: Cloud-init ISO not found. VM may not configure automatically."
fi

# Note: Ubuntu Server 24.04 requires kernel boot parameters to enable autoinstall mode.
# The cloud-init ISO is attached, but you must manually add kernel parameters at boot.
echo "✓ Cloud-init ISO attached to VM"

echo "VM created successfully"

# =============================================================================
# START VM
# =============================================================================
echo ""
echo "=== Starting VM ==="
qm start "$VMID"

echo ""
echo "=============================================================================="
echo "IMPORTANT: Manual Boot Configuration Required"
echo "=============================================================================="
echo ""
echo "The VM is starting. To enable automatic installation, you MUST manually"
echo "add kernel boot parameters when the GRUB menu appears:"
echo ""
echo "1. Open the VM console in Proxmox web UI"
echo "2. When the GRUB boot menu appears, press 'e' to edit the boot entry"
echo "3. Find the line starting with 'linux' or 'linuxefi'"
echo "4. Add 'autoinstall ds=nocloud' at the END of that line"
echo "   (add a space before 'autoinstall')"
echo "5. Press 'Ctrl+X' or 'F10' to boot with these parameters"
echo ""
echo "Example (add parameters BEFORE the --- separator):"
echo "  Before: linux /casper/vmlinuz quiet ---"
echo "  After:  linux /casper/vmlinuz quiet autoinstall ds=nocloud ---"
echo ""
echo "Note: The '---' separator divides kernel parameters (before) from initrd"
echo "      parameters (after). Both positions may work, but placing parameters"
echo "      before '---' is the standard approach for autoinstall."
echo ""
echo "Once you've added the parameters and booted, the installation will"
echo "proceed automatically using the cloud-init configuration."
echo ""
echo "=============================================================================="
echo ""
echo "Waiting for VM to boot (you need to add kernel parameters first)..."
echo "After adding parameters and booting, installation will take 5-10 minutes..."
echo ""

# Wait for VM to get an IP address
MAX_WAIT=600  # 10 minutes
WAITED=0
VM_IP=""
VM_STATUS=""

while [[ $WAITED -lt $MAX_WAIT ]]; do
    sleep 10
    WAITED=$((WAITED + 10))
    
    # Check VM status
    VM_STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}' || echo "unknown")
    if [[ "$VM_STATUS" != "running" ]]; then
        echo "  VM status: $VM_STATUS (waiting for it to start...)"
        continue
    fi
    
    # Method 1: Try qemu-guest-agent (most reliable if agent is ready)
    if [[ -z "$VM_IP" ]]; then
        GUEST_OUTPUT=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null || echo "")
        if [[ -n "$GUEST_OUTPUT" ]]; then
            # Extract first IPv4 address from JSON output
            VM_IP=$(echo "$GUEST_OUTPUT" | grep -oE '"ip-address":\s*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo "")
            # Filter out 127.0.0.1 if found
            if [[ "$VM_IP" == "127.0.0.1" ]]; then
                VM_IP=""
            fi
        fi
    fi
    
    # Method 2: Try to get MAC address and check ARP table
    if [[ -z "$VM_IP" ]]; then
        MAC_ADDR=$(qm config "$VMID" 2>/dev/null | grep -i "net0:" | grep -oE '([a-f0-9]{2}:){5}[a-f0-9]{2}' | head -1 || echo "")
        if [[ -n "$MAC_ADDR" ]]; then
            # Check ARP table for this MAC
            VM_IP=$(arp -an 2>/dev/null | grep -i "$MAC_ADDR" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
        fi
    fi
    
    # Method 3: Try scanning common IP ranges (if static IP was set, try that first)
    if [[ -z "$VM_IP" && "$STATIC_IP" != "dhcp" ]]; then
        # If static IP was configured, try that
        if ping -c 1 -W 2 "$STATIC_IP" &>/dev/null; then
            VM_IP="$STATIC_IP"
        fi
    fi
    
    # Test SSH connectivity if we found an IP
    if [[ -n "$VM_IP" ]]; then
        if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes docker@"$VM_IP" "echo 'connected'" 2>/dev/null; then
            echo "✓ VM is ready! IP: $VM_IP"
            break
        else
            # IP found but SSH not ready yet
            echo "  Found IP: $VM_IP (waiting for SSH to be ready...)"
            VM_IP=""  # Clear it so we keep trying
        fi
    else
        # Show progress with status
        if (( WAITED % 30 == 0 )); then
            echo "  Still waiting for VM IP... (${WAITED}s / ${MAX_WAIT}s)"
            echo "    VM Status: $VM_STATUS"
            echo "    Tip: Check Proxmox console to see boot progress"
        fi
    fi
done

if [[ -z "$VM_IP" ]]; then
    echo ""
    echo "⚠ WARNING: Could not automatically detect VM IP address after ${MAX_WAIT}s"
    echo ""
    echo "The VM may still be booting or cloud-init may still be running."
    echo "You can:"
    echo "  1. Check the Proxmox web UI console to see the VM's boot progress"
    echo "  2. Wait a few more minutes and check the VM's IP manually"
    echo "  3. If using DHCP, check your router's DHCP client list"
    echo "  4. If using static IP ($STATIC_IP), try: ssh -i $SSH_KEY_FILE docker@$STATIC_IP"
    echo ""
    echo "Once you have the IP, SSH into the VM using:"
    echo "  ssh -i $SSH_KEY_FILE docker@<VM_IP>"
    echo ""
    VM_IP="<check Proxmox console>"
fi

# Cleanup
rm -rf "$CLOUD_INIT_DIR"
rm -f "/tmp/cloud-init-${VMID}.iso"

# =============================================================================
# VERIFY INSTALLATION
# =============================================================================
if [[ "$VM_IP" != "<check Proxmox console>" ]]; then
    echo ""
    echo "=== Verifying installation ==="
    
    ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no docker@"$VM_IP" << 'REMOTE_EOF'
        echo "Checking Docker installation..."
        docker --version
        docker compose version
        
        echo ""
        echo "Checking NFS mounts..."
        mount | grep nfs || echo "NFS mounts may still be mounting..."
        
        echo ""
        echo "Checking directory structure..."
        ls -la /opt/stacks/
        ls -la /mnt/docker-data/ | head -5
REMOTE_EOF
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=========================================="
echo "Docker VM Setup Complete!"
echo "=========================================="
echo ""
echo "VM ID:         $VMID"
echo "Hostname:      $HOSTNAME"
echo "IP Address:    $VM_IP"
echo ""
echo "SSH Access:"
echo "  ssh -i $SSH_KEY_FILE docker@$VM_IP"
echo ""
echo "Docker Stacks: /opt/stacks/"
echo "  - arr-stack/"
echo "  - tandoor/"
echo "  - support-services/"
echo ""
echo "Data Storage:  /mnt/docker-data/ (NFS from Synology NAS)"
echo "Media:         /mnt/media/ (NFS from Synology NAS)"
echo "Torrents:      /mnt/torrents/ (NFS from Synology NAS)"
echo ""
echo "Next steps:"
echo "1. SSH into the VM: ssh -i $SSH_KEY_FILE docker@$VM_IP"
echo "2. Copy docker-compose files to /opt/stacks/"
echo "3. Copy .env file and configure"
echo "4. Start stacks: docker compose up -d"
echo ""
echo "Note: NFS mounts may take a moment to establish. Check with: mount | grep nfs"
echo ""
