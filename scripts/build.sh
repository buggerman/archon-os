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

# Btrfs subvolume configuration
readonly SUBVOL_OS_A="@os_a"         # Primary OS subvolume (active)
readonly SUBVOL_OS_B="@os_b"         # Secondary OS subvolume (update target)
readonly SUBVOL_HOME="@home"         # User data persistence
readonly SUBVOL_LOG="@log"           # System logs isolation
readonly SUBVOL_SWAP="@swap"         # Swap file containment
readonly SUBVOL_ROOT="@"             # Root subvolume (container)

# Mount options for immutable root filesystem
readonly MOUNT_OPTS_RO="ro,noatime,compress=zstd:1,space_cache=v2"
readonly MOUNT_OPTS_RW="rw,noatime,compress=zstd:1,space_cache=v2"

# Package configuration - Sacred Minimal Core
readonly BASE_PACKAGES=(
    # Core system
    "base"
    "linux"
    "linux-firmware"
    "btrfs-progs"
    "systemd"
    "systemd-boot"
    
    # Network and hardware
    "networkmanager"
    "bluez"
    "bluez-utils"
    
    # Desktop environment (KDE Plasma minimal)
    "plasma-desktop"
    "plasma-wayland-session"
    "sddm"
    "konsole"
    "dolphin"
    "kate"
    
    # Application platforms
    "flatpak"
    
    # Essential utilities
    "sudo"
    "which"
    "nano"
    "git"
    "curl"
    "wget"
    "unzip"
    "tar"
    
    # Development foundation (for LinuxBrew)
    "base-devel"
    "gcc"
    
    # Audio (minimal)
    "pipewire"
    "pipewire-pulse"
    "pipewire-alsa"
)

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
    
    # Unmount subvolumes in reverse order
    local mount_points=(
        "${MOUNT_DIR}/swap"
        "${MOUNT_DIR}/var/log"
        "${MOUNT_DIR}/home"
        "${MOUNT_DIR}/boot"
        "${MOUNT_DIR}"
    )
    
    for mount_point in "${mount_points[@]}"; do
        if mountpoint -q "${mount_point}" 2>/dev/null; then
            umount "${mount_point}" || log_warn "Failed to unmount ${mount_point}"
        fi
    done
    
    # Clean up any temporary mounts
    if mountpoint -q "${WORK_DIR}/btrfs_temp" 2>/dev/null; then
        umount "${WORK_DIR}/btrfs_temp" || log_warn "Failed to unmount temporary Btrfs mount"
    fi
    
    if mountpoint -q "${WORK_DIR}/verify_temp" 2>/dev/null; then
        umount "${WORK_DIR}/verify_temp" || log_warn "Failed to unmount verification mount"
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
        "btrfs"
        "parted"
        "losetup"
        "mount"
        "umount"
        "findmnt"
        "blkid"
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

# Btrfs subvolume functions
create_btrfs_subvolumes() {
    log_step "Creating Btrfs subvolume layout"
    
    # Mount root Btrfs filesystem temporarily to create subvolumes
    local temp_mount="${WORK_DIR}/btrfs_temp"
    mkdir -p "${temp_mount}"
    
    log_info "Mounting Btrfs root filesystem"
    mount "${LOOP_DEVICE_ROOT}" "${temp_mount}"
    
    # Create all required subvolumes
    log_info "Creating atomic A/B subvolumes"
    btrfs subvolume create "${temp_mount}/${SUBVOL_OS_A}"
    btrfs subvolume create "${temp_mount}/${SUBVOL_OS_B}"
    
    log_info "Creating persistent data subvolumes"
    btrfs subvolume create "${temp_mount}/${SUBVOL_HOME}"
    btrfs subvolume create "${temp_mount}/${SUBVOL_LOG}"
    btrfs subvolume create "${temp_mount}/${SUBVOL_SWAP}"
    
    # Set default subvolume to @os_a for initial boot
    local subvol_id
    subvol_id=$(btrfs subvolume list "${temp_mount}" | grep "${SUBVOL_OS_A}" | awk '{print $2}')
    btrfs subvolume set-default "${subvol_id}" "${temp_mount}"
    
    log_info "Subvolume structure:"
    btrfs subvolume list "${temp_mount}"
    
    # Unmount temporary mount
    umount "${temp_mount}"
    rmdir "${temp_mount}"
    
    log_success "Btrfs subvolumes created successfully"
}

mount_subvolumes_for_install() {
    log_step "Mounting subvolumes for system installation"
    
    # Mount the active OS subvolume as root
    log_info "Mounting ${SUBVOL_OS_A} as root filesystem"
    mount -o "${MOUNT_OPTS_RW},subvol=${SUBVOL_OS_A}" "${LOOP_DEVICE_ROOT}" "${MOUNT_DIR}"
    
    # Create mount points for other subvolumes and EFI
    mkdir -p "${MOUNT_DIR}"/{boot,home,var/log,swap}
    
    # Mount EFI partition
    log_info "Mounting EFI partition"
    mount "${LOOP_DEVICE_EFI}" "${MOUNT_DIR}/boot"
    
    # Mount persistent data subvolumes
    log_info "Mounting persistent data subvolumes"
    mount -o "${MOUNT_OPTS_RW},subvol=${SUBVOL_HOME}" "${LOOP_DEVICE_ROOT}" "${MOUNT_DIR}/home"
    mount -o "${MOUNT_OPTS_RW},subvol=${SUBVOL_LOG}" "${LOOP_DEVICE_ROOT}" "${MOUNT_DIR}/var/log"
    mount -o "${MOUNT_OPTS_RW},subvol=${SUBVOL_SWAP}" "${LOOP_DEVICE_ROOT}" "${MOUNT_DIR}/swap"
    
    # Verify mount structure
    log_info "Current mount structure:"
    findmnt "${MOUNT_DIR}" || true
    
    log_success "Subvolumes mounted successfully"
}

verify_subvolume_layout() {
    log_step "Verifying subvolume layout"
    
    # Mount root filesystem temporarily to verify subvolumes
    local temp_mount="${WORK_DIR}/verify_temp"
    mkdir -p "${temp_mount}"
    mount "${LOOP_DEVICE_ROOT}" "${temp_mount}"
    
    log_info "Subvolume verification:"
    local subvolumes=("${SUBVOL_OS_A}" "${SUBVOL_OS_B}" "${SUBVOL_HOME}" "${SUBVOL_LOG}" "${SUBVOL_SWAP}")
    
    for subvol in "${subvolumes[@]}"; do
        if [[ -d "${temp_mount}/${subvol}" ]]; then
            log_info "✓ ${subvol} exists"
        else
            log_error "✗ ${subvol} missing"
            umount "${temp_mount}"
            rmdir "${temp_mount}"
            exit 1
        fi
    done
    
    # Check default subvolume
    local default_subvol
    default_subvol=$(btrfs subvolume get-default "${temp_mount}" | awk '{print $NF}')
    log_info "Default subvolume: ${default_subvol}"
    
    umount "${temp_mount}"
    rmdir "${temp_mount}"
    
    log_success "Subvolume layout verified successfully"
}

# System installation functions
setup_pacman_mirrors() {
    log_step "Setting up package mirrors"
    
    # Ensure we have the latest mirrorlist
    log_info "Refreshing pacman mirrors"
    
    # Use reflector to get the fastest mirrors (if available)
    if command -v reflector &> /dev/null; then
        log_info "Using reflector to optimize mirrors"
        reflector --country 'United States' --age 6 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
    else
        log_info "Using default mirrorlist"
    fi
    
    # Update package databases
    pacman -Sy --noconfirm
    
    log_success "Package mirrors configured"
}

bootstrap_base_system() {
    log_step "Bootstrapping ArchonOS base system"
    
    log_info "Installing base system with pacstrap"
    log_info "Target: ${MOUNT_DIR}"
    log_info "Packages: ${#BASE_PACKAGES[@]} total"
    
    # Show package list being installed
    log_info "Package list:"
    for pkg in "${BASE_PACKAGES[@]}"; do
        log_info "  - ${pkg}"
    done
    
    # Execute pacstrap with our minimal package set
    log_info "Executing pacstrap (this may take several minutes)..."
    if ! pacstrap "${MOUNT_DIR}" "${BASE_PACKAGES[@]}"; then
        log_error "pacstrap failed to install base system"
        exit 1
    fi
    
    log_success "Base system bootstrapped successfully"
}

verify_installation() {
    log_step "Verifying system installation"
    
    # Check critical system files exist
    local critical_files=(
        "${MOUNT_DIR}/usr/bin/systemd"
        "${MOUNT_DIR}/usr/bin/plasma-desktop"
        "${MOUNT_DIR}/usr/bin/sddm"
        "${MOUNT_DIR}/usr/bin/konsole"
        "${MOUNT_DIR}/usr/bin/flatpak"
    )
    
    log_info "Checking critical system files:"
    for file in "${critical_files[@]}"; do
        if [[ -f "${file}" ]]; then
            log_info "✓ ${file##*/} installed"
        else
            log_error "✗ ${file##*/} missing"
            exit 1
        fi
    done
    
    # Check if kernel is installed
    if [[ -f "${MOUNT_DIR}/boot/vmlinuz-linux" ]]; then
        log_info "✓ Linux kernel installed"
    else
        log_error "✗ Linux kernel missing"
        exit 1
    fi
    
    # Verify package count
    local installed_count
    installed_count=$(arch-chroot "${MOUNT_DIR}" pacman -Q | wc -l)
    log_info "Total packages installed: ${installed_count}"
    
    if [[ ${installed_count} -lt 50 ]]; then
        log_warn "Package count seems low (${installed_count}), but continuing..."
    fi
    
    log_success "System installation verified"
}

install_base_system() {
    log_step "Installing ArchonOS base system"
    
    setup_pacman_mirrors
    bootstrap_base_system
    verify_installation
    
    log_success "Base system installation completed"
}

# System configuration functions
generate_fstab() {
    log_step "Generating fstab with immutable root configuration"
    
    log_info "Creating fstab with read-only root filesystem"
    
    # Get filesystem UUIDs
    local root_uuid efi_uuid
    root_uuid=$(blkid -s UUID -o value "${LOOP_DEVICE_ROOT}")
    efi_uuid=$(blkid -s UUID -o value "${LOOP_DEVICE_EFI}")
    
    log_info "Root UUID: ${root_uuid}"
    log_info "EFI UUID: ${efi_uuid}"
    
    # Create fstab with proper mount options
    cat > "${MOUNT_DIR}/etc/fstab" << EOF
# ArchonOS fstab - Immutable Root Filesystem Configuration
# <file system>                               <dir>      <type>  <options>                                           <dump>  <pass>

# Root subvolume (read-only for immutability)
UUID=${root_uuid}                             /          btrfs   ${MOUNT_OPTS_RO},subvol=${SUBVOL_OS_A}              0       1

# EFI System Partition
UUID=${efi_uuid}                              /boot      vfat    rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro  0  2

# Persistent data subvolumes (read-write)
UUID=${root_uuid}                             /home      btrfs   ${MOUNT_OPTS_RW},subvol=${SUBVOL_HOME}              0       2
UUID=${root_uuid}                             /var/log   btrfs   ${MOUNT_OPTS_RW},subvol=${SUBVOL_LOG}               0       2
UUID=${root_uuid}                             /swap      btrfs   ${MOUNT_OPTS_RW},subvol=${SUBVOL_SWAP}              0       2

# Temporary filesystems
tmpfs                                         /tmp       tmpfs   defaults,noatime,mode=1777                          0       0
tmpfs                                         /var/tmp   tmpfs   defaults,noatime,mode=1777                          0       0
EOF
    
    log_success "fstab generated successfully"
}

copy_configuration_script() {
    log_step "Copying system configuration script"
    
    local config_script="${PROJECT_ROOT}/scripts/configure-system.sh"
    local target_script="${MOUNT_DIR}/tmp/configure-system.sh"
    
    if [[ ! -f "${config_script}" ]]; then
        log_error "Configuration script not found: ${config_script}"
        exit 1
    fi
    
    log_info "Copying configuration script to chroot environment"
    cp "${config_script}" "${target_script}"
    chmod +x "${target_script}"
    
    log_success "Configuration script copied successfully"
}

execute_system_configuration() {
    log_step "Executing system configuration via arch-chroot"
    
    # Set configuration environment variables
    local config_env=(
        "HOSTNAME=archonos"
        "TIMEZONE=UTC"
        "LOCALE=en_US.UTF-8"
        "KEYMAP=us"
    )
    
    log_info "Configuration parameters:"
    for env_var in "${config_env[@]}"; do
        log_info "  - ${env_var}"
    done
    
    # Execute configuration script in chroot
    log_info "Executing configuration script in chroot environment"
    for env_var in "${config_env[@]}"; do
        export "${env_var}"
    done
    
    if ! arch-chroot "${MOUNT_DIR}" /tmp/configure-system.sh; then
        log_error "System configuration failed"
        exit 1
    fi
    
    # Clean up configuration script
    rm -f "${MOUNT_DIR}/tmp/configure-system.sh"
    
    log_success "System configuration completed successfully"
}

configure_system() {
    log_step "Configuring ArchonOS system"
    
    generate_fstab
    copy_configuration_script
    execute_system_configuration
    
    log_success "System configuration phase completed"
}

prepare_disk() {
    log_step "Preparing disk for ArchonOS installation"
    
    create_disk_image
    create_partition_table
    setup_loop_devices
    format_efi_partition
    format_root_partition
    verify_disk_layout
    create_btrfs_subvolumes
    verify_subvolume_layout
    mount_subvolumes_for_install
    
    log_success "Disk preparation completed successfully"
}

# Main build function
build_image() {
    log_step "Building ArchonOS image"
    
    # Prepare disk, partitions, and subvolumes
    prepare_disk
    
    # Install base system using pacstrap
    install_base_system
    
    # Configure system via arch-chroot
    configure_system
    
    # Placeholder for subsequent phases
    log_info "Bootloader setup will be implemented in Phase 7"
    log_info "ISO creation will be implemented in Phase 8"
    
    log_success "ArchonOS system configuration completed"
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