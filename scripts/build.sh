#!/bin/bash
#
# ArchonOS Build Script
# Builds an atomic, immutable Arch Linux distribution
#
# This script creates a bootable ISO with:
# - Read-only root filesystem
# - Btrfs A/B subvolume layout for atomic updates
# - KDE Plasma on Wayland
# - Flatpak and LinuxBrew integration
#

# Strict error handling
set -euo pipefail

# Build configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
readonly BUILD_DIR="${BUILD_DIR:-/tmp/archonos-build}"
readonly IMAGE_NAME="${IMAGE_NAME:-archonos}"
readonly DISK_SIZE="4G"
readonly ARCH="x86_64"

# Build metadata
readonly BUILD_DATE="$(date -u +%Y%m%d)"
readonly BUILD_TIME="$(date -u +%H%M%S)"
readonly BUILD_VERSION="${GITHUB_RUN_NUMBER:-dev}"
readonly BUILD_COMMIT="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')}"

# Partition configuration
readonly EFI_SIZE="512M"
readonly ROOT_PARTITION_TYPE="8304"  # Linux root (x86-64)
readonly EFI_PARTITION_TYPE="ef00"   # EFI System Partition

# Loop device variables
LOOP_DEVICE=""
LOOP_DEVICE_ROOT=""
LOOP_DEVICE_EFI=""

# Derived paths
readonly WORK_DIR="${BUILD_DIR}/work"
readonly MOUNT_DIR="${BUILD_DIR}/mnt"
readonly ISO_DIR="${BUILD_DIR}/iso"
readonly IMAGE_FILE="${BUILD_DIR}/${IMAGE_NAME}.img"
readonly ISO_FILE="${BUILD_DIR}/${IMAGE_NAME}-${BUILD_VERSION}-${BUILD_DATE}.iso"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_step() {
    echo -e "\n${BLUE}[STEP]${NC} $*" >&2
}

cleanup_loop_devices() {
    log_info "Cleaning up loop devices"
    
    # Unmount any mounted filesystems
    if mountpoint -q "${MOUNT_DIR}/boot" 2>/dev/null; then
        umount "${MOUNT_DIR}/boot" || log_warn "Failed to unmount boot partition"
    fi
    
    if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
        umount "${MOUNT_DIR}" || log_warn "Failed to unmount root partition"
    fi
    
    # Detach loop devices
    if [[ -n "${LOOP_DEVICE}" ]]; then
        losetup -d "${LOOP_DEVICE}" || log_warn "Failed to detach loop device ${LOOP_DEVICE}"
    fi
    
    log_info "Loop device cleanup completed"
}

# Error handling
cleanup() {
    local exit_code=$?
    
    if [[ ${exit_code} -ne 0 ]]; then
        log_error "Build failed with exit code ${exit_code}"
    fi
    
    log_info "Cleaning up build artifacts..."
    
    # Clean up loop devices and mounts
    cleanup_loop_devices
    
    # Remove temporary files (but keep build outputs)
    rm -rf "${WORK_DIR}" || true
    
    if [[ ${exit_code} -eq 0 ]]; then
        log_success "Build completed successfully"
        log_info "ISO file: ${ISO_FILE}"
    fi
    
    exit ${exit_code}
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Validation functions
check_dependencies() {
    log_step "Checking build dependencies"
    
    local missing_deps=()
    local required_commands=(
        "pacstrap"
        "arch-chroot"
        "mkfs.btrfs"
        "parted"
        "losetup"
        "mount"
        "umount"
        "xorriso"
    )
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "${cmd}" &> /dev/null; then
            missing_deps+=("${cmd}")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install the missing packages and try again"
        exit 1
    fi
    
    log_success "All dependencies satisfied"
}

check_privileges() {
    log_step "Checking privileges"
    
    if [[ ${EUID} -ne 0 ]]; then
        log_error "This script must be run as root"
        log_error "Use: sudo ${0}"
        exit 1
    fi
    
    log_success "Running with sufficient privileges"
}

validate_environment() {
    log_step "Validating build environment"
    
    # Check available disk space (need at least 8GB)
    local available_space
    available_space=$(df "${BUILD_DIR%/*}" --output=avail | tail -n1)
    local required_space=$((8 * 1024 * 1024)) # 8GB in KB
    
    if [[ ${available_space} -lt ${required_space} ]]; then
        log_error "Insufficient disk space"
        log_error "Required: 8GB, Available: $((available_space / 1024 / 1024))GB"
        exit 1
    fi
    
    # Check if loop device support is available
    if ! modprobe loop 2>/dev/null; then
        log_warn "Could not load loop module, assuming it's built-in"
    fi
    
    log_success "Environment validation passed"
}

# Build preparation
prepare_build_environment() {
    log_step "Preparing build environment"
    
    # Create required directories
    mkdir -p "${WORK_DIR}" "${MOUNT_DIR}" "${ISO_DIR}"
    
    # Clean up any existing image file
    rm -f "${IMAGE_FILE}" "${ISO_FILE}"
    
    log_success "Build environment prepared"
}

# Disk preparation functions
create_disk_image() {
    log_step "Creating disk image"
    
    log_info "Creating ${DISK_SIZE} disk image: ${IMAGE_FILE}"
    
    # Create sparse file for the disk image
    truncate -s "${DISK_SIZE}" "${IMAGE_FILE}"
    
    # Set up loop device for the entire disk
    LOOP_DEVICE=$(losetup --find --show "${IMAGE_FILE}")
    log_info "Loop device created: ${LOOP_DEVICE}"
    
    log_success "Disk image created successfully"
}

create_partition_table() {
    log_step "Creating partition table"
    
    log_info "Creating GPT partition table on ${LOOP_DEVICE}"
    
    # Create GPT partition table
    parted -s "${LOOP_DEVICE}" mklabel gpt
    
    # Create EFI System Partition (ESP)
    parted -s "${LOOP_DEVICE}" mkpart ESP fat32 1MiB "${EFI_SIZE}"
    parted -s "${LOOP_DEVICE}" set 1 esp on
    
    # Create root partition (remaining space)
    parted -s "${LOOP_DEVICE}" mkpart primary btrfs "${EFI_SIZE}" 100%
    
    # Force kernel to re-read partition table
    partprobe "${LOOP_DEVICE}"
    
    log_success "Partition table created successfully"
}

setup_loop_devices() {
    log_step "Setting up partition loop devices"
    
    # Wait for partition devices to be available
    sleep 2
    
    # Set up loop devices for individual partitions
    LOOP_DEVICE_EFI="${LOOP_DEVICE}p1"
    LOOP_DEVICE_ROOT="${LOOP_DEVICE}p2"
    
    # Verify partition devices exist
    if [[ ! -b "${LOOP_DEVICE_EFI}" ]]; then
        log_error "EFI partition device not found: ${LOOP_DEVICE_EFI}"
        exit 1
    fi
    
    if [[ ! -b "${LOOP_DEVICE_ROOT}" ]]; then
        log_error "Root partition device not found: ${LOOP_DEVICE_ROOT}"
        exit 1
    fi
    
    log_info "EFI partition: ${LOOP_DEVICE_EFI}"
    log_info "Root partition: ${LOOP_DEVICE_ROOT}"
    
    log_success "Loop devices configured successfully"
}

format_efi_partition() {
    log_step "Formatting EFI partition"
    
    log_info "Creating FAT32 filesystem on ${LOOP_DEVICE_EFI}"
    
    # Format EFI partition as FAT32
    mkfs.fat -F 32 -n "ARCHONOS_EFI" "${LOOP_DEVICE_EFI}"
    
    log_success "EFI partition formatted successfully"
}

format_root_partition() {
    log_step "Formatting root partition"
    
    log_info "Creating Btrfs filesystem on ${LOOP_DEVICE_ROOT}"
    
    # Format root partition as Btrfs
    mkfs.btrfs -f -L "ARCHONOS_ROOT" "${LOOP_DEVICE_ROOT}"
    
    log_success "Root partition formatted successfully"
}

verify_disk_layout() {
    log_step "Verifying disk layout"
    
    log_info "Partition information:"
    parted -s "${LOOP_DEVICE}" print
    
    log_info "Filesystem information:"
    lsblk "${LOOP_DEVICE}"
    
    log_success "Disk layout verified successfully"
}

prepare_disk() {
    log_step "Preparing disk for ArchonOS installation"
    
    create_disk_image
    create_partition_table
    setup_loop_devices
    format_efi_partition
    format_root_partition
    verify_disk_layout
    
    log_success "Disk preparation completed successfully"
}

# Main build function
build_image() {
    log_step "Building ArchonOS image"
    
    # Prepare disk and partitions
    prepare_disk
    
    # Placeholder for subsequent phases
    log_info "Btrfs subvolume creation will be implemented in Phase 4"
    log_info "System installation will be implemented in Phase 5"
    log_info "Bootloader setup will be implemented in Phase 7"
    log_info "ISO creation will be implemented in Phase 8"
    
    log_success "Image preparation completed"
}

# Display build information
show_build_info() {
    log_step "Build Information"
    
    echo "Project: ArchonOS"
    echo "Version: ${BUILD_VERSION}"
    echo "Date: ${BUILD_DATE}"
    echo "Time: ${BUILD_TIME}"
    echo "Commit: ${BUILD_COMMIT}"
    echo "Architecture: ${ARCH}"
    echo "Disk Size: ${DISK_SIZE}"
    echo "Build Directory: ${BUILD_DIR}"
    echo "Output ISO: ${ISO_FILE}"
}

# Main execution flow
main() {
    log_info "Starting ArchonOS build process"
    
    show_build_info
    check_dependencies
    check_privileges
    validate_environment
    prepare_build_environment
    build_image
    
    log_success "ArchonOS build process completed"
}

# Execute main function
main "$@"