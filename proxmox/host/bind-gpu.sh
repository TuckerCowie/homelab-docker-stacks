#!/bin/bash
# =============================================================================
# Intel GPU Binding Helper Script
# =============================================================================
# Manually binds Intel GPU to i915 or xe driver, unbinding from vfio-pci if needed.
# This is useful if the GPU gets bound to VFIO (e.g., by a VM configuration).
#
# Usage: ./bind-gpu.sh [i915|xe]
#   If no argument provided, auto-detects best driver (prefers i915 for media)
#
# Run this script on the Proxmox host as root.
# =============================================================================

set -euo pipefail

# Detect GPU PCI ID
GPU_PCI_ID=$(lspci -nn | grep -i "vga.*intel\|display.*intel" | head -1 | grep -oP '\d+:\d+:\d+\.\d+' || echo "00:02.0")
GPU_INFO=$(lspci -nn | grep -i "vga.*intel\|display.*intel" | head -1)

if [[ -z "$GPU_INFO" ]]; then
    echo "ERROR: Intel GPU not found"
    exit 1
fi

echo "GPU detected: $GPU_INFO"
echo "GPU PCI ID: $GPU_PCI_ID"

# Determine which driver to use
TARGET_DRIVER="${1:-auto}"

if [[ "$TARGET_DRIVER" == "auto" ]]; then
    # Prefer i915 for media transcoding (Jellyfin, etc.)
    if lsmod | grep -q "^i915"; then
        TARGET_DRIVER="i915"
        echo "Auto-detected: i915 (preferred for media transcoding)"
    elif lsmod | grep -q "^xe"; then
        TARGET_DRIVER="xe"
        echo "Auto-detected: xe"
    elif modinfo i915 &>/dev/null 2>&1; then
        TARGET_DRIVER="i915"
        echo "Auto-detected: i915 (loading module)"
        modprobe i915
    elif modinfo xe &>/dev/null 2>&1; then
        TARGET_DRIVER="xe"
        echo "Auto-detected: xe (loading module)"
        modprobe xe
    else
        echo "ERROR: Neither i915 nor xe driver available"
        exit 1
    fi
fi

# Validate driver choice
if [[ "$TARGET_DRIVER" != "i915" ]] && [[ "$TARGET_DRIVER" != "xe" ]]; then
    echo "ERROR: Invalid driver. Use 'i915' or 'xe'"
    exit 1
fi

# Check if driver module is loaded
if ! lsmod | grep -q "^${TARGET_DRIVER}"; then
    echo "Loading ${TARGET_DRIVER} driver..."
    modprobe "$TARGET_DRIVER" || {
        echo "ERROR: Failed to load ${TARGET_DRIVER} driver"
        exit 1
    }
fi

# Check current binding
CURRENT_DRIVER=$(lspci -k -s "$GPU_PCI_ID" 2>/dev/null | grep "Kernel driver in use" | awk '{print $4}' || echo "none")

if [[ "$CURRENT_DRIVER" == "$TARGET_DRIVER" ]]; then
    echo "✓ GPU is already bound to ${TARGET_DRIVER} driver"
    exit 0
fi

echo "Current driver: ${CURRENT_DRIVER}"
echo "Target driver: ${TARGET_DRIVER}"

# Unbind from current driver
if [[ "$CURRENT_DRIVER" != "none" ]] && [[ -e "/sys/bus/pci/drivers/${CURRENT_DRIVER}/unbind" ]]; then
    echo "Unbinding from ${CURRENT_DRIVER}..."
    echo "0000:${GPU_PCI_ID}" > "/sys/bus/pci/drivers/${CURRENT_DRIVER}/unbind" 2>/dev/null || {
        echo "WARNING: Could not unbind from ${CURRENT_DRIVER} (may need to stop using VMs/LXCs)"
    }
    sleep 1
fi

# Bind to target driver
echo "Binding to ${TARGET_DRIVER}..."
if echo "0000:${GPU_PCI_ID}" > "/sys/bus/pci/drivers/${TARGET_DRIVER}/bind" 2>/dev/null; then
    sleep 1
    # Verify binding
    NEW_DRIVER=$(lspci -k -s "$GPU_PCI_ID" 2>/dev/null | grep "Kernel driver in use" | awk '{print $4}' || echo "none")
    if [[ "$NEW_DRIVER" == "$TARGET_DRIVER" ]]; then
        echo "✓ GPU successfully bound to ${TARGET_DRIVER} driver"
        
        # Check if /dev/dri appears
        sleep 1
        if [[ -d /dev/dri ]] && [[ -n "$(ls -A /dev/dri 2>/dev/null)" ]]; then
            echo "✓ DRI devices available:"
            ls -1 /dev/dri/
        else
            echo "⚠ DRI devices not yet available (may take a moment)"
        fi
    else
        echo "⚠ GPU binding may have failed (current: ${NEW_DRIVER})"
        exit 1
    fi
else
    echo "ERROR: Failed to bind GPU to ${TARGET_DRIVER}"
    echo "  Make sure no VMs are using GPU passthrough"
    echo "  Check: lspci -k -s ${GPU_PCI_ID}"
    exit 1
fi
