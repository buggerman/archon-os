#!/bin/bash
#
# ArchonOS Installer Script
# Simple installer that leverages dd for disk image deployment
#
# Usage: install-archonos.sh [target_device]
# Example: install-archonos.sh /dev/sda
#

# Strict error handling
set -euo pipefail

# Configuration
readonly ARCHONOS_IMAGE="/archonos/archonos.img"

# Simple logging
log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# Check requirements
[[ $EUID -eq 0 ]] || error "Must run as root. Use: sudo $0 $*"
[[ -f "$ARCHONOS_IMAGE" ]] || error "ArchonOS image not found: $ARCHONOS_IMAGE"

# Get target device
TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "Available storage devices:"
    lsblk -d -o NAME,SIZE,MODEL | grep -E "(sd|nvme|vd)"
    echo
    read -p "Enter target device (e.g., /dev/sda): " TARGET
fi

# Validate target
[[ -b "$TARGET" ]] || error "Invalid device: $TARGET"

# Check if mounted
if mount | grep -q "^$TARGET"; then
    error "Device $TARGET is mounted. Unmount all partitions first."
fi

# Final confirmation
echo
echo "WARNING: This will COMPLETELY ERASE $TARGET"
echo "All data will be lost permanently!"
echo
read -p "Type 'YES' to continue: " confirm
[[ "$confirm" == "YES" ]] || error "Installation cancelled"

# Deploy image
echo
log "Deploying ArchonOS to $TARGET..."
log "This may take several minutes..."

# Use dd to write the disk image
if command -v pv >/dev/null 2>&1; then
    # Use pv for progress if available
    pv "$ARCHONOS_IMAGE" | dd of="$TARGET" bs=4M conv=fsync
else
    # Use dd with progress
    dd if="$ARCHONOS_IMAGE" of="$TARGET" bs=4M status=progress conv=fsync
fi

# Ensure data is synced
sync

log "Expanding filesystem to use full disk..."

# Re-read partition table
partprobe "$TARGET" 2>/dev/null || true
sleep 2

# Determine partition names (handle both /dev/sda2 and /dev/nvme0n1p2 formats)
if [[ "$TARGET" =~ nvme ]]; then
    ROOT_PART="${TARGET}p2"
else
    ROOT_PART="${TARGET}2"
fi

# Expand the partition to use remaining space
log "Expanding partition $ROOT_PART..."
parted "$TARGET" resizepart 2 100% 2>/dev/null || true

# Expand the Btrfs filesystem
log "Expanding Btrfs filesystem..."
mkdir -p /tmp/archonos-expand
mount -o subvol=@os_a "$ROOT_PART" /tmp/archonos-expand
btrfs filesystem resize max /tmp/archonos-expand
umount /tmp/archonos-expand
rmdir /tmp/archonos-expand

log "Installation completed successfully!"
echo
echo "ArchonOS has been installed to $TARGET"
echo
echo "Default login credentials:"
echo "  Username: archon"
echo "  Password: archon"
echo
echo "Please reboot and remove the installation media."
echo

read -p "Reboot now? [y/N]: " reboot_choice
if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
    reboot
fi