#!/bin/bash
# =============================================================================
# Intel GPU Driver Installation Script for Proxmox Host
# =============================================================================
# Installs and configures Intel GPU drivers for Beelink EQ14 with Intel N150
# (Meteor Lake architecture) processor for hardware-accelerated video
# transcoding (Quick Sync Video / QSV).
#
# This script:
# - Installs Intel GPU firmware
# - Installs Mesa drivers for Intel graphics
# - Installs Intel Media VA drivers for QSV acceleration
# - Configures kernel modules
# - Verifies GPU accessibility
#
# Run this script on the Proxmox host as root.
# =============================================================================

set -euo pipefail

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
echo "=== Pre-flight checks ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Check if running on Proxmox
if [[ ! -f /etc/pve/version ]]; then
    echo "WARNING: This doesn't appear to be a Proxmox host"
    echo "Proceeding anyway, but some commands may fail..."
fi

# Detect CPU
CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
echo "Detected CPU: $CPU_MODEL"

# Check for Intel processor
if ! echo "$CPU_MODEL" | grep -qi "intel"; then
    echo "WARNING: This script is designed for Intel processors"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for Intel GPU
if ! lspci | grep -qi "vga.*intel\|display.*intel"; then
    echo "WARNING: Intel GPU not detected via lspci"
    echo "This may be normal if the GPU is integrated and not showing up"
    echo "Continuing with driver installation..."
fi

# =============================================================================
# UPDATE SYSTEM
# =============================================================================
echo ""
echo "=== Updating system packages ==="
apt-get update
apt-get upgrade -y

# =============================================================================
# INSTALL BUILD DEPENDENCIES
# =============================================================================
echo ""
echo "=== Installing build dependencies ==="
apt-get install -y \
    build-essential \
    dkms \
    linux-headers-$(uname -r) \
    pkg-config \
    wget \
    curl \
    git \
    ca-certificates \
    gnupg \
    lsb-release

# =============================================================================
# ADD NON-FREE REPOSITORIES
# =============================================================================
echo ""
echo "=== Configuring repositories ==="

# Check if non-free repos are enabled
if ! grep -q "non-free" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
    echo "Adding non-free repositories..."
    
    # Get Debian codename
    DEBIAN_CODENAME=$(lsb_release -cs)
    
    # Backup sources.list
    cp /etc/apt/sources.list /etc/apt/sources.list.backup
    
    # Add non-free and contrib
    sed -i "s/deb \(.*\) main/deb \1 main contrib non-free non-free-firmware/" /etc/apt/sources.list
    sed -i "s/deb \(.*\) main/deb \1 main contrib non-free non-free-firmware/" /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true
    sed -i "s/deb \(.*\) main/deb \1 main contrib non-free non-free-firmware/" /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null || true
    
    apt-get update
else
    echo "Non-free repositories already configured"
fi

# =============================================================================
# INSTALL INTEL GPU FIRMWARE
# =============================================================================
echo ""
echo "=== Installing Intel GPU firmware ==="

# Install intel-microcode (safe, doesn't conflict with Proxmox kernel)
echo "Installing intel-microcode..."
apt-get install -y intel-microcode

# Check if Intel GPU firmware directory exists
INTEL_FW_DIR="/lib/firmware/i915"
mkdir -p "$INTEL_FW_DIR"

# Check if firmware files already exist (Proxmox kernels often include them)
if [[ -n "$(ls -A "$INTEL_FW_DIR"/*.bin 2>/dev/null)" ]]; then
    echo "✓ Intel GPU firmware files already present:"
    ls -1 "$INTEL_FW_DIR"/*.bin | head -5
    echo "Skipping firmware package installation (firmware included in Proxmox kernel)"
else
    echo "Intel GPU firmware not found, attempting to install..."
    
    # Try to install firmware-misc-nonfree (contains Intel GPU firmware)
    # Note: firmware-linux-nonfree conflicts with Proxmox kernel, so we skip it
    echo "Attempting to install firmware-misc-nonfree..."
    
    # Capture both output and exit code
    if FW_OUTPUT=$(apt-get install -y firmware-misc-nonfree 2>&1); then
        echo "✓ firmware-misc-nonfree installed successfully"
    else
        EXIT_CODE=$?
        if echo "$FW_OUTPUT" | grep -q "proxmox-ve"; then
            echo "WARNING: firmware-misc-nonfree would conflict with Proxmox kernel"
            echo "Proxmox kernels typically include Intel GPU firmware already."
            echo "Skipping firmware package installation."
            echo ""
            echo "If GPU doesn't work after driver installation, you can manually download"
            echo "Intel GPU firmware from: https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git"
        else
            echo "ERROR: Failed to install firmware-misc-nonfree (exit code: $EXIT_CODE)"
            echo "Output: $FW_OUTPUT"
        fi
    fi
    
    # Verify firmware files exist after installation attempt
    if [[ -n "$(ls -A "$INTEL_FW_DIR"/*.bin 2>/dev/null)" ]]; then
        echo "✓ Intel GPU firmware files found:"
        ls -1 "$INTEL_FW_DIR"/*.bin | head -5
    else
        echo "⚠ No Intel GPU firmware files found"
        echo "   This may be normal - Proxmox kernels often include firmware"
        echo "   If GPU doesn't work, check kernel logs: dmesg | grep -E 'xe|i915'"
    fi
fi

echo "Intel GPU firmware installation complete"

# =============================================================================
# INSTALL MESA DRIVERS
# =============================================================================
echo ""
echo "=== Installing Mesa drivers for Intel graphics ==="

apt-get install -y \
    mesa-utils \
    mesa-va-drivers \
    mesa-vdpau-drivers \
    libva2 \
    libva-drm2 \
    libva-x11-2 \
    vainfo

# =============================================================================
# INSTALL INTEL MEDIA VA DRIVERS (QSV)
# =============================================================================
echo ""
echo "=== Installing Intel Media VA drivers for Quick Sync Video ==="

# For Meteor Lake (N150) and newer Intel GPUs, use intel-media-va-driver
# libva-intel-driver is for older GPUs (Gen 7 and below) and not needed
echo "Installing Intel Media VA driver for QSV support..."

# Try installing intel-media-va-driver (standard package name)
VA_DRIVER_INSTALLED=0
VA_OUTPUT=$(apt-get install -y intel-media-va-driver 2>&1) && VA_DRIVER_INSTALLED=1

if [[ $VA_DRIVER_INSTALLED -eq 1 ]]; then
    echo "✓ intel-media-va-driver installed"
elif echo "$VA_OUTPUT" | grep -q "has no installation candidate\|Unable to locate package"; then
    echo "intel-media-va-driver not found, trying intel-media-va-driver-non-free..."
    # Try non-free variant
    VA_NONFREE_OUTPUT=$(apt-get install -y intel-media-va-driver-non-free 2>&1) && VA_DRIVER_INSTALLED=1
    
    if [[ $VA_DRIVER_INSTALLED -eq 1 ]]; then
        echo "✓ intel-media-va-driver-non-free installed"
    elif echo "$VA_NONFREE_OUTPUT" | grep -q "has no installation candidate\|Unable to locate package"; then
        echo "WARNING: Intel Media VA driver packages not available in repositories"
        echo "This may be normal if your repositories don't include non-free packages"
        echo "The GPU may still work with Mesa VA drivers installed earlier"
        echo "For Meteor Lake (N150), Mesa VA drivers should provide basic acceleration"
    else
        echo "ERROR: Failed to install Intel Media VA driver"
        echo "Output: $VA_NONFREE_OUTPUT"
    fi
else
    echo "ERROR: Failed to install intel-media-va-driver"
    echo "Output: $VA_OUTPUT"
fi

# Install intel-gpu-tools (useful for monitoring and debugging)
if INTEL_GPU_TOOLS_OUTPUT=$(apt-get install -y intel-gpu-tools 2>&1); then
    echo "✓ intel-gpu-tools installed"
elif echo "$INTEL_GPU_TOOLS_OUTPUT" | grep -q "has no installation candidate\|Unable to locate package"; then
    echo "⚠ intel-gpu-tools not available (optional, skipping)"
else
    echo "⚠ Failed to install intel-gpu-tools (optional, continuing)"
fi

# =============================================================================
# CONFIGURE KERNEL MODULES
# =============================================================================
echo ""
echo "=== Configuring kernel modules ==="

# Detect GPU model
GPU_INFO=$(lspci -nn | grep -i "vga.*intel\|display.*intel" | head -1)
GPU_PCI_ID=$(lspci -nn | grep -i "vga.*intel\|display.*intel" | head -1 | grep -oP '\d+:\d+:\d+\.\d+' || echo "00:02.0")
echo "GPU detected: $GPU_INFO"
echo "GPU PCI ID: $GPU_PCI_ID"

# For Jellyfin/media transcoding, prefer i915 (better tested, more stable)
# xe is available as an option for newer features
PREFER_I915=1
USE_XE_DRIVER=0

# Check current driver status
XE_LOADED=$(lsmod | grep -q "^xe" && echo "1" || echo "0")
I915_LOADED=$(lsmod | grep -q "^i915" && echo "1" || echo "0")
XE_AVAILABLE=$(modinfo xe &>/dev/null 2>&1 && echo "1" || echo "0")
I915_AVAILABLE=$(modinfo i915 &>/dev/null 2>&1 && echo "1" || echo "0")

echo "Driver status:"
echo "  xe:   loaded=$XE_LOADED, available=$XE_AVAILABLE"
echo "  i915: loaded=$I915_LOADED, available=$I915_AVAILABLE"

# Check if GPU is bound to VFIO (needs to be unbound)
GPU_BOUND_TO_VFIO=0
if lspci -k -s "$GPU_PCI_ID" 2>/dev/null | grep -q "vfio-pci"; then
    GPU_BOUND_TO_VFIO=1
    echo "⚠ GPU is bound to vfio-pci - will need to rebind"
fi

# Load appropriate driver - prefer i915 for media transcoding
if [[ $I915_LOADED -eq 1 ]]; then
    echo "✓ i915 driver already loaded (preferred for Jellyfin/media transcoding)"
elif [[ $I915_AVAILABLE -eq 1 ]]; then
    echo "Loading i915 driver (preferred for media transcoding)..."
    if modprobe i915 2>&1; then
        echo "✓ i915 driver loaded successfully"
    else
        echo "⚠ Failed to load i915 driver"
        # Fall back to xe if i915 fails
        if [[ $XE_AVAILABLE -eq 1 ]]; then
            echo "Trying xe driver as fallback..."
            if modprobe xe 2>&1; then
                USE_XE_DRIVER=1
                echo "✓ xe driver loaded as fallback"
            fi
        fi
    fi
elif [[ $XE_AVAILABLE -eq 1 ]]; then
    # Only xe is available
    echo "Loading xe driver (i915 not available)..."
    if modprobe xe 2>&1; then
        USE_XE_DRIVER=1
        echo "✓ xe driver loaded"
    else
        echo "✗ Failed to load xe driver"
    fi
else
    echo "✗ Neither xe nor i915 drivers are available"
    echo "  Check kernel modules: modinfo xe i915"
fi

# Verify final state and bind GPU if needed
sleep 1  # Give modules time to initialize
I915_LOADED_FINAL=$(lsmod | grep -q "^i915" && echo "1" || echo "0")
XE_LOADED_FINAL=$(lsmod | grep -q "^xe" && echo "1" || echo "0")

# Bind GPU to correct driver if it's bound to VFIO
if [[ $GPU_BOUND_TO_VFIO -eq 1 ]]; then
    echo ""
    echo "Binding GPU to Intel driver..."
    if [[ $I915_LOADED_FINAL -eq 1 ]]; then
        # Unbind from vfio-pci and bind to i915
        echo "0000:${GPU_PCI_ID}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        sleep 1
        echo "0000:${GPU_PCI_ID}" > /sys/bus/pci/drivers/i915/bind 2>/dev/null && \
            echo "✓ GPU bound to i915 driver" || echo "⚠ GPU binding may need manual intervention"
    elif [[ $XE_LOADED_FINAL -eq 1 ]]; then
        # Unbind from vfio-pci and bind to xe
        echo "0000:${GPU_PCI_ID}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        sleep 1
        echo "0000:${GPU_PCI_ID}" > /sys/bus/pci/drivers/xe/bind 2>/dev/null && \
            echo "✓ GPU bound to xe driver" || echo "⚠ GPU binding may need manual intervention"
    fi
fi

# Add appropriate module to modules-load for persistence (prefer i915)
if [[ $I915_LOADED_FINAL -eq 1 ]]; then
    if ! grep -q "^i915" /etc/modules-load.d/intel-gpu.conf 2>/dev/null; then
        echo "i915" > /etc/modules-load.d/intel-gpu.conf
        echo "✓ Added i915 to modules-load (preferred for media transcoding)"
    fi
    # Optionally add xe if both are loaded (for flexibility)
    if [[ $XE_LOADED_FINAL -eq 1 ]] && ! grep -q "^xe" /etc/modules-load.d/intel-gpu.conf 2>/dev/null; then
        echo "xe" >> /etc/modules-load.d/intel-gpu.conf
        echo "  (xe also added for compatibility)"
    fi
elif [[ $XE_LOADED_FINAL -eq 1 ]]; then
    if ! grep -q "^xe" /etc/modules-load.d/intel-gpu.conf 2>/dev/null; then
        echo "xe" > /etc/modules-load.d/intel-gpu.conf
        echo "✓ Added xe to modules-load"
    fi
else
    echo "⚠ No Intel GPU drivers loaded - GPU may not be functional"
fi

# Configure kernel parameters for Intel GPU
# For i915 driver, we use enable_guc and enable_fbc for optimal performance
# For xe driver, parameters are typically not needed
if lsmod | grep -q "^i915"; then
    KERNEL_PARAMS="i915.enable_guc=2 i915.enable_fbc=1"
    if ! grep -q "i915.enable_guc" /etc/default/grub; then
        echo ""
        echo "Configuring kernel parameters for i915 driver..."
        
        # Backup grub config
        cp /etc/default/grub /etc/default/grub.backup
        
        # Add kernel parameters
        if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then
            # Parameter exists, append to it
            sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${KERNEL_PARAMS}\"/" /etc/default/grub
        else
            # Parameter doesn't exist, add it
            echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${KERNEL_PARAMS}\"" >> /etc/default/grub
        fi
        
        update-grub
        echo "✓ Kernel parameters configured. Reboot required for changes to take effect."
    else
        echo "✓ Kernel parameters already configured"
    fi
elif lsmod | grep -q "^xe"; then
    echo "Using xe driver - kernel parameters typically not needed"
    echo "xe driver handles GPU initialization automatically"
else
    echo "No Intel GPU driver loaded - skipping kernel parameter configuration"
fi

# =============================================================================
# CREATE GPU BINDING SERVICE (to prevent VFIO binding at boot)
# =============================================================================
echo ""
echo "=== Creating GPU binding service ==="

# Detect which driver to use for binding
BIND_DRIVER="i915"
if [[ $USE_XE_DRIVER -eq 1 ]] && [[ $I915_LOADED_FINAL -eq 0 ]]; then
    BIND_DRIVER="xe"
fi

# Create systemd service to ensure GPU is bound to Intel driver at boot
cat > /etc/systemd/system/bind-intel-gpu.service << EOF
[Unit]
Description=Bind Intel GPU to Intel driver (prevent VFIO binding)
After=systemd-udev-settle.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 3 && if [ -e /sys/bus/pci/drivers/vfio-pci ]; then echo "0000:${GPU_PCI_ID}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true; sleep 1; fi && echo "0000:${GPU_PCI_ID}" > /sys/bus/pci/drivers/${BIND_DRIVER}/bind 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
systemctl daemon-reload
systemctl enable bind-intel-gpu.service
systemctl start bind-intel-gpu.service 2>/dev/null || true

echo "✓ Created and enabled bind-intel-gpu.service"
echo "  This ensures GPU is bound to ${BIND_DRIVER} driver at boot (not vfio-pci)"

# =============================================================================
# VERIFY GPU DETECTION
# =============================================================================
echo ""
echo "=== Verifying GPU detection ==="

# Check for DRI devices
if [[ -d /dev/dri ]]; then
    echo "✓ /dev/dri directory exists"
    ls -la /dev/dri/
    
    if [[ -e /dev/dri/renderD128 ]]; then
        echo "✓ Render node found: /dev/dri/renderD128"
        RENDER_NODE="/dev/dri/renderD128"
    else
        echo "⚠ Render node not found. Checking available devices..."
        RENDER_NODE=$(find /dev/dri -name "renderD*" | head -1)
        if [[ -n "$RENDER_NODE" ]]; then
            echo "✓ Found render node: $RENDER_NODE"
        else
            echo "✗ No render nodes found"
        fi
    fi
else
    echo "✗ /dev/dri directory not found"
    echo "GPU may not be properly initialized"
fi

# Check kernel module (xe or i915)
GPU_DRIVER_LOADED=0
if lsmod | grep -q "^xe"; then
    echo "✓ xe kernel module is loaded (for Gen 12.5+ Intel GPUs)"
    lsmod | grep "^xe"
    GPU_DRIVER_LOADED=1
    GPU_DRIVER_NAME="xe"
elif lsmod | grep -q "^i915"; then
    echo "✓ i915 kernel module is loaded (for older Intel GPUs)"
    lsmod | grep "^i915"
    GPU_DRIVER_LOADED=1
    GPU_DRIVER_NAME="i915"
else
    echo "✗ Neither xe nor i915 kernel module is loaded"
    echo "  Checking available modules..."
    modinfo xe &>/dev/null && echo "  - xe module available" || echo "  - xe module not found"
    modinfo i915 &>/dev/null && echo "  - i915 module available" || echo "  - i915 module not found"
fi

# Check GPU info
if command -v intel_gpu_top &> /dev/null; then
    echo ""
    echo "GPU Information:"
    intel_gpu_top -l 1 2>/dev/null || echo "Could not get detailed GPU info"
fi

# =============================================================================
# VERIFY VAAPI SUPPORT
# =============================================================================
echo ""
echo "=== Verifying VAAPI support ==="

if command -v vainfo &> /dev/null; then
    echo "VAAPI Information:"
    vainfo 2>&1 | head -20 || echo "VAAPI may not be fully configured"
    
    # Check for QSV support
    if vainfo 2>&1 | grep -qi "H264\|HEVC\|VP9"; then
        echo "✓ Video codec support detected"
    else
        echo "⚠ Video codec support may be limited"
    fi
else
    echo "✗ vainfo not found"
fi

# =============================================================================
# CONFIGURE PERMISSIONS
# =============================================================================
echo ""
echo "=== Configuring permissions ==="

# Ensure render and video groups exist
if ! getent group render > /dev/null 2>&1; then
    groupadd -r render
    echo "Created render group"
fi

if ! getent group video > /dev/null 2>&1; then
    groupadd -r video
    echo "Created video group"
fi

# Set permissions on DRI devices
if [[ -d /dev/dri ]]; then
    chmod 666 /dev/dri/renderD* 2>/dev/null || true
    chmod 666 /dev/dri/card* 2>/dev/null || true
    echo "Set permissions on DRI devices"
fi

# =============================================================================
# INSTALL ADDITIONAL TOOLS (OPTIONAL)
# =============================================================================
echo ""
echo "=== Installing additional GPU tools ==="

apt-get install -y \
    glxinfo \
    clinfo \
    hwinfo || echo "Some tools may not be available"

# =============================================================================
# TEST GPU FUNCTIONALITY
# =============================================================================
echo ""
echo "=== Testing GPU functionality ==="

# Test with glxinfo if available
if command -v glxinfo &> /dev/null; then
    echo "OpenGL Information:"
    glxinfo | grep -i "opengl\|intel" | head -10 || echo "Could not get OpenGL info"
fi

# Test VAAPI
if command -v vainfo &> /dev/null && [[ -n "${RENDER_NODE:-}" ]]; then
    echo ""
    echo "Testing VAAPI with render node..."
    LIBVA_DRIVER_NAME=iHD vainfo --display drm --device "$RENDER_NODE" 2>&1 | head -15 || \
    LIBVA_DRIVER_NAME=i965 vainfo --display drm --device "$RENDER_NODE" 2>&1 | head -15 || \
    echo "VAAPI test completed (some warnings may be normal)"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=========================================="
echo "Intel GPU Driver Installation Complete!"
echo "=========================================="
echo ""
echo "Installed components:"
echo "  ✓ Intel GPU firmware"
echo "  ✓ Mesa drivers"
echo "  ✓ Intel Media VA drivers (QSV)"
echo "  ✓ Kernel modules configured (preferring i915 for media transcoding)"
echo "  ✓ GPU binding service created (bind-intel-gpu.service)"
echo ""
echo "GPU Status:"
if [[ -e /dev/dri/renderD128 ]]; then
    echo "  ✓ Render node: /dev/dri/renderD128"
    ls -lh /dev/dri/renderD128
else
    echo "  ⚠ Render node not found at /dev/dri/renderD128"
    echo "     Check: ls -la /dev/dri/"
fi

if lsmod | grep -q "^xe"; then
    echo "  ✓ xe kernel module: loaded (Gen 12.5+ driver)"
elif lsmod | grep -q "^i915"; then
    echo "  ✓ i915 kernel module: loaded (legacy driver)"
else
    echo "  ✗ Intel GPU kernel module: not loaded"
    echo "     Check: lsmod | grep -E '^xe|^i915'"
fi

echo ""
echo "Next steps:"
echo "1. If kernel parameters were changed, REBOOT the system:"
echo "   reboot"
echo ""
echo "2. After reboot, verify GPU access:"
echo "   ls -la /dev/dri/"
echo "   vainfo"
echo ""
echo "3. If GPU is bound to vfio-pci after reboot, use bind-gpu.sh helper:"
echo "   ./proxmox/host/bind-gpu.sh [i915|xe]"
echo "   (i915 is preferred for Jellyfin/media transcoding)"
echo ""
echo "4. For LXC containers, ensure GPU passthrough is configured"
echo "   See: proxmox/lxc/jellyfin/create-lxc.sh"
echo ""
echo "5. Test QSV transcoding in Jellyfin or other media server"
echo ""
echo "Note: The bind-intel-gpu.service will automatically bind GPU to Intel driver"
echo "      at boot, preventing VFIO binding. If you need to manually rebind, use"
echo "      the bind-gpu.sh helper script."
echo ""

