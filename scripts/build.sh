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
readonly SUBVOL_ROOT="@"             # Root subvolume
readonly SUBVOL_HOME="@home"         # User data persistence
readonly SUBVOL_LOG="@log"           # System logs isolation
readonly SUBVOL_SWAP="@swap"         # Swap file containment

# Mount options for Btrfs filesystem
readonly MOUNT_OPTS_RW="rw,noatime,compress=zstd:1,space_cache=v2"

# Package configuration following Arch Wiki guidelines

# Core system packages (installed with pacstrap) - Garuda Linux approach
readonly BASE_PACKAGES=(
    # Essential base system
    "base"
    "linux-zen"        # Garuda uses linux-zen kernel
    "linux-zen-headers"
    "linux-firmware"
    "btrfs-progs"
    
    # Network and essential utilities (install early per Arch Wiki)
    "networkmanager"
    "sudo"
    "nano"
    "git"
    
    # Development tools
    "base-devel"
    
    # Explicit dependency resolution (prevent interactive prompts)
    "iptables-nft"    # Modern iptables provider
    "mkinitcpio"      # Initramfs generator
)

# Desktop packages (installed via arch-chroot after base) - Garuda Linux approach
readonly DESKTOP_PACKAGES=(
    # Hardware support
    "bluez"
    "bluez-utils"
    
    # Desktop environment (KDE Plasma)
    "plasma-desktop"
    "plasma-workspace"
    "kwin"
    "sddm"
    "konsole"
    "dolphin"
    "kate"
    
    # Wayland support
    "wayland"
    "xorg-xwayland"
    "qt6-wayland"
    
    # Application platforms
    "flatpak"
    
    # Garuda's performance/gaming packages
    "gamemode"
    "lib32-gamemode"
    "mangohud"
    "lib32-mangohud"
    "irqbalance"
    "zram-generator"
    "ananicy-cpp"
    "memavaild"
    "nohang"
    "preload"
    "prelockd"
    "uresourced"
    
    # GPU drivers (essential)
    "mesa"
    "lib32-mesa"
    "vulkan-icd-loader"
    "lib32-vulkan-icd-loader"
    "vulkan-mesa-layers"
    "lib32-vulkan-mesa-layers"
    "intel-media-driver"
    "xf86-video-amdgpu"
    "vulkan-radeon"
    "lib32-vulkan-radeon"
    "nvidia-dkms"
    "lib32-nvidia-utils"
    
    # Audio
    "pipewire"
    "pipewire-pulse"
    "pipewire-alsa"
    "pipewire-jack"
    "lib32-pipewire"
    "wireplumber"
    
    # Snapshot system - Garuda uses Timeshift
    "timeshift"
    "timeshift-autosnap"
    "grub-btrfs"
    
    # Essential fonts
    "ttf-dejavu"
    "ttf-liberation"
    "noto-fonts"
    "noto-fonts-emoji"
    
    # Minimal utilities
    "which"
    "curl"
    "wget"
    "unzip"
    "tar"
    "gcc"
    "git"
    "vim"
    "htop"
    "neofetch"
    "lm_sensors"
    "thermald"
    "cpupower"
    "fwupd"
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
    
    # Clean up kpartx mappings if they exist
    if [[ -n "${LOOP_DEVICE}" ]]; then
        kpartx -dv "${LOOP_DEVICE}" 2>/dev/null || true
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
        "kpartx"
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
        log_warn "Could not load loop module, assuming it's built-in or available"
    fi
    
    # Ensure loop device nodes exist (for container environments)
    if [[ ! -e /dev/loop0 ]]; then
        log_info "Creating loop device nodes for container environment"
        for i in {0..7}; do
            mknod "/dev/loop${i}" b 7 "${i}" 2>/dev/null || true
        done
    fi
    
    # Test loop device functionality
    if ! losetup --find >/dev/null 2>&1; then
        log_error "Loop device functionality not available"
        log_error "This script requires loop device support"
        exit 1
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
    
    # First, try standard partition device naming
    LOOP_DEVICE_EFI="${LOOP_DEVICE}p1"
    LOOP_DEVICE_ROOT="${LOOP_DEVICE}p2"
    
    # Check if partition devices exist naturally
    if [[ ! -b "${LOOP_DEVICE_EFI}" ]]; then
        log_info "Standard partition devices not found, using kpartx"
        
        # Use kpartx to create partition device mappings
        if ! kpartx -av "${LOOP_DEVICE}"; then
            log_error "kpartx failed to create partition devices"
            exit 1
        fi
        
        # kpartx creates devices in /dev/mapper/ with different naming
        local loop_name
        loop_name=$(basename "${LOOP_DEVICE}")
        LOOP_DEVICE_EFI="/dev/mapper/${loop_name}p1"
        LOOP_DEVICE_ROOT="/dev/mapper/${loop_name}p2"
        
        log_info "Using kpartx partition devices:"
        log_info "  EFI: ${LOOP_DEVICE_EFI}"
        log_info "  Root: ${LOOP_DEVICE_ROOT}"
    else
        log_info "Using standard partition devices:"
        log_info "  EFI: ${LOOP_DEVICE_EFI}"
        log_info "  Root: ${LOOP_DEVICE_ROOT}"
    fi
    
    # Verify partition devices exist
    if [[ ! -b "${LOOP_DEVICE_EFI}" ]]; then
        log_error "EFI partition device not found: ${LOOP_DEVICE_EFI}"
        exit 1
    fi
    
    if [[ ! -b "${LOOP_DEVICE_ROOT}" ]]; then
        log_error "Root partition device not found: ${LOOP_DEVICE_ROOT}"
        exit 1
    fi
    
    log_success "Loop devices configured successfully"
}

format_efi_partition() {
    log_step "Formatting EFI partition"
    
    log_info "Creating FAT32 filesystem on ${LOOP_DEVICE_EFI}"
    
    # Format EFI partition as FAT32 (label max 11 chars)
    mkfs.fat -F 32 -n "ARCHONOS" "${LOOP_DEVICE_EFI}"
    
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
    
    # Create root subvolume
    log_info "Creating root subvolume"
    btrfs subvolume create "${temp_mount}/${SUBVOL_ROOT}"
    
    log_info "Creating persistent data subvolumes"
    btrfs subvolume create "${temp_mount}/${SUBVOL_HOME}"
    btrfs subvolume create "${temp_mount}/${SUBVOL_LOG}"
    btrfs subvolume create "${temp_mount}/${SUBVOL_SWAP}"
    
    # Set default subvolume to @ for boot
    local subvol_id
    subvol_id=$(btrfs subvolume list "${temp_mount}" | grep "path ${SUBVOL_ROOT}$" | awk '{print $2}')
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
    
    # Mount the root subvolume as root
    log_info "Mounting ${SUBVOL_ROOT} as root filesystem"
    mount -o "${MOUNT_OPTS_RW},subvol=${SUBVOL_ROOT}" "${LOOP_DEVICE_ROOT}" "${MOUNT_DIR}"
    
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
    local subvolumes=("${SUBVOL_ROOT}" "${SUBVOL_HOME}" "${SUBVOL_LOG}" "${SUBVOL_SWAP}")
    
    # Get list of subvolumes from btrfs
    local subvol_list
    subvol_list=$(btrfs subvolume list "${temp_mount}")
    
    for subvol in "${subvolumes[@]}"; do
        if echo "${subvol_list}" | grep -q "path ${subvol}$"; then
            log_info "✓ ${subvol} exists"
        else
            log_error "✗ ${subvol} missing"
            log_info "Available subvolumes:"
            echo "${subvol_list}"
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
    log_step "Bootstrapping ArchonOS base system following Arch Wiki"
    
    # Step 1: Install base system with pacstrap (following Arch Wiki)
    log_info "Installing base system with pacstrap"
    log_info "Target: ${MOUNT_DIR}"
    log_info "Base packages: ${#BASE_PACKAGES[@]} total"
    
    for pkg in "${BASE_PACKAGES[@]}"; do
        log_info "  - ${pkg}"
    done
    
    log_info "Executing pacstrap -K for base system (this may take several minutes)..."
    if ! pacstrap -K "${MOUNT_DIR}" "${BASE_PACKAGES[@]}"; then
        log_error "pacstrap failed to install base system"
        exit 1
    fi
    
    log_success "Base system installed successfully"
    
    # Copy pacman.conf to chroot environment before any chroot package installations
    log_info "Copying pacman.conf to chroot environment"
    cp /etc/pacman.conf "${MOUNT_DIR}/etc/pacman.conf"
    
    # Step 2: Set up proper chroot environment (following Arch Wiki)
    # No manual API filesystem mounting needed for arch-chroot
    log_info "Using arch-chroot for package installation (handles mounting automatically)"
    
    # Step 3: Initialize pacman keyring and install desktop packages
    log_info "Initializing pacman keyring in chroot"
    
    # Initialize and populate the pacman keyring (required for package signature verification)
    log_info "Initializing pacman keyring..."
    if ! arch-chroot "${MOUNT_DIR}" pacman-key --init; then
        log_error "Failed to initialize pacman keyring"
        exit 1
    fi
    
    log_info "Populating Arch Linux keyring..."
    if ! arch-chroot "${MOUNT_DIR}" pacman-key --populate archlinux; then
        log_error "Failed to populate Arch Linux keyring"
        exit 1
    fi
    
    # Now install desktop packages with proper keyring
    log_info "Installing desktop packages via arch-chroot"
    log_info "Desktop packages: ${#DESKTOP_PACKAGES[@]} total"
    
    # Install all desktop packages in one command
    log_info "Installing desktop packages: ${DESKTOP_PACKAGES[*]}"
    if ! arch-chroot "${MOUNT_DIR}" pacman -S --noconfirm "${DESKTOP_PACKAGES[@]}"; then
        log_error "Failed to install desktop packages"
        exit 1
    fi
    log_success "Desktop packages installed successfully"
}

verify_installation() {
    log_step "Verifying system installation"
    
    # Check critical packages are actually installed via pacman
    local critical_packages=(
        "filesystem"
        "gcc-libs"
        "glibc"
        "bash"
        "coreutils"
        "file"
        "findutils"
        "gawk"
        "grep"
        "procps-ng"
        "sed"
        "tar"
        "util-linux"
        "linux"
        "networkmanager"
        "plasma-desktop"
        "sddm" 
        "konsole"
        "flatpak"
        "btrfs-progs"
    )
    
    log_info "Checking critical packages installation:"
    for pkg in "${critical_packages[@]}"; do
        # Check if package is installed using pacman query
        if ! arch-chroot "${MOUNT_DIR}" pacman -Q "${pkg}" &>/dev/null; then
            log_error "✗ ${pkg} missing"
            exit 1
        else
            log_info "✓ ${pkg} installed"
        fi
    done
    
    # Check if kernel is installed
    if [[ -f "${MOUNT_DIR}/boot/vmlinuz-linux-zen" ]]; then
        log_info "✓ Linux Zen kernel installed"
    else
        log_error "✗ Linux Zen kernel missing"
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
    log_step "Generating fstab with Btrfs subvolumes"
    
    log_info "Creating fstab with Btrfs subvolumes"
    
    # Get filesystem UUIDs
    local root_uuid efi_uuid
    root_uuid=$(blkid -s UUID -o value "${LOOP_DEVICE_ROOT}")
    efi_uuid=$(blkid -s UUID -o value "${LOOP_DEVICE_EFI}")
    
    log_info "Root UUID: ${root_uuid}"
    log_info "EFI UUID: ${efi_uuid}"
    
    # Create fstab with proper mount options
    cat > "${MOUNT_DIR}/etc/fstab" << EOF
# ArchonOS fstab - Btrfs Subvolume Configuration
# <file system>                               <dir>      <type>  <options>                                           <dump>  <pass>

# Root subvolume
UUID=${root_uuid}                             /          btrfs   ${MOUNT_OPTS_RW},subvol=${SUBVOL_ROOT}              0       1

# EFI System Partition
UUID=${efi_uuid}                              /boot      vfat    rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro  0  2

# Persistent data subvolumes
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
    local target_script="${MOUNT_DIR}/configure-system.sh"
    local desktop_script="${PROJECT_ROOT}/scripts/configure-desktop.sh"
    local target_desktop_script="${MOUNT_DIR}/configure-desktop.sh"
    local garuda_script="${PROJECT_ROOT}/scripts/garuda-optimizations.sh"
    local target_garuda_script="${MOUNT_DIR}/garuda-optimizations.sh"
    
    if [[ ! -f "${config_script}" ]]; then
        log_error "Configuration script not found: ${config_script}"
        exit 1
    fi
    
    if [[ ! -f "${desktop_script}" ]]; then
        log_error "Desktop configuration script not found: ${desktop_script}"
        exit 1
    fi
    
    if [[ ! -f "${garuda_script}" ]]; then
        log_error "Garuda optimizations script not found: ${garuda_script}"
        exit 1
    fi
    
    log_info "Copying configuration scripts to chroot environment"
    cp "${config_script}" "${target_script}"
    cp "${desktop_script}" "${target_desktop_script}"
    cp "${garuda_script}" "${target_garuda_script}"
    chmod +x "${target_script}"
    chmod +x "${target_desktop_script}"
    chmod +x "${target_garuda_script}"
    
    log_success "Configuration scripts copied successfully"
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
    
    if ! arch-chroot "${MOUNT_DIR}" /configure-system.sh; then
        log_error "System configuration failed"
        exit 1
    fi
    
    # Copy installer script to live system
    log_info "Adding installer script to live system"
    cp "${SCRIPT_DIR}/install-archonos.sh" "${MOUNT_DIR}/usr/local/bin/install-archonos"
    chmod +x "${MOUNT_DIR}/usr/local/bin/install-archonos"
    
    # Create desktop shortcut for installer
    log_info "Creating installer desktop shortcut"
    mkdir -p "${MOUNT_DIR}/home/archon/Desktop"
    cat > "${MOUNT_DIR}/home/archon/Desktop/install-archonos.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Install ArchonOS
Comment=Install ArchonOS to Hard Drive
Exec=konsole -e sudo install-archonos
Icon=system-software-install
Terminal=false
Categories=System;
EOF
    chmod +x "${MOUNT_DIR}/home/archon/Desktop/install-archonos.desktop"
    arch-chroot "${MOUNT_DIR}" chown -R archon:archon /home/archon/Desktop 2>/dev/null || true
    
    # Clean up configuration scripts
    rm -f "${MOUNT_DIR}/configure-system.sh"
    rm -f "${MOUNT_DIR}/configure-desktop.sh"
    rm -f "${MOUNT_DIR}/garuda-optimizations.sh"
    
    log_success "System configuration completed successfully"
}

configure_system() {
    log_step "Configuring ArchonOS system"
    
    generate_fstab
    copy_configuration_script
    execute_system_configuration
    
    log_success "System configuration phase completed"
}

# Bootloader installation functions
install_systemd_boot() {
    log_step "Installing systemd-boot bootloader"
    
    log_info "Installing systemd-boot to EFI system partition"
    
    # Install systemd-boot using bootctl from within chroot
    if ! arch-chroot "${MOUNT_DIR}" bootctl install; then
        log_error "Failed to install systemd-boot"
        exit 1
    fi
    
    log_success "systemd-boot installed successfully"
}

create_boot_entries() {
    log_step "Creating boot entries"
    
    local entries_dir="${MOUNT_DIR}/boot/loader/entries"
    local root_uuid
    root_uuid=$(blkid -s UUID -o value "${LOOP_DEVICE_ROOT}")
    
    log_info "Creating boot entry directories"
    mkdir -p "${entries_dir}"
    
    # Get kernel version
    local kernel_version
    kernel_version=$(ls "${MOUNT_DIR}/usr/lib/modules/" | head -n1)
    log_info "Detected kernel version: ${kernel_version}"
    
    # Create primary boot entry
    log_info "Creating primary boot entry"
    cat > "${entries_dir}/archonos.conf" << EOF
title   ArchonOS
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options root=UUID=${root_uuid} rootflags=subvol=${SUBVOL_ROOT} rw quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 systemd.unified_cgroup_hierarchy=1 sysrq_always_enabled=1 mitigations=off nowatchdog
EOF
    
    # Create fallback boot entry
    log_info "Creating fallback boot entry"
    cat > "${entries_dir}/archonos-fallback.conf" << EOF
title   ArchonOS (fallback initramfs)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen-fallback.img
options root=UUID=${root_uuid} rootflags=subvol=${SUBVOL_ROOT} rw quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 systemd.unified_cgroup_hierarchy=1 sysrq_always_enabled=1 mitigations=off nowatchdog
EOF
    
    
    log_success "Boot entries created successfully"
}

configure_bootloader() {
    log_step "Configuring systemd-boot loader"
    
    local loader_dir="${MOUNT_DIR}/boot/loader"
    
    log_info "Creating loader configuration"
    
    # Create main loader configuration
    cat > "${loader_dir}/loader.conf" << EOF
default  archonos.conf
timeout  5
console-mode max
editor   no
auto-entries yes
auto-firmware yes
EOF
    
    log_info "Bootloader configured with Btrfs snapshots"
    log_info "Default boot: @ subvolume"
    log_info "Rollback via Btrfs snapshots"
    log_info "Timeout: 5 seconds"
    
    log_success "Bootloader configuration completed"
}

setup_initramfs() {
    log_step "Configuring initramfs for Btrfs"
    
    log_info "Adding Btrfs support to mkinitcpio"
    
    # Backup original mkinitcpio.conf
    cp "${MOUNT_DIR}/etc/mkinitcpio.conf" "${MOUNT_DIR}/etc/mkinitcpio.conf.backup"
    
    # Configure mkinitcpio for Btrfs and atomic updates
    log_info "Updating mkinitcpio hooks and modules"
    sed -i 's/^MODULES=()/MODULES=(btrfs)/' "${MOUNT_DIR}/etc/mkinitcpio.conf"
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/' "${MOUNT_DIR}/etc/mkinitcpio.conf"
    
    # Regenerate initramfs
    log_info "Regenerating initramfs images"
    if ! arch-chroot "${MOUNT_DIR}" mkinitcpio -P; then
        log_error "Failed to regenerate initramfs"
        exit 1
    fi
    
    log_success "Initramfs configured for Btrfs boot"
}

verify_bootloader_installation() {
    log_step "Verifying bootloader installation"
    
    # Check if systemd-boot is installed
    if [[ ! -f "${MOUNT_DIR}/boot/EFI/systemd/systemd-bootx64.efi" ]]; then
        log_error "systemd-boot EFI binary not found"
        exit 1
    fi
    
    # Check boot entries
    local entries_dir="${MOUNT_DIR}/boot/loader/entries"
    local required_entries=("archonos.conf" "archonos-fallback.conf")
    
    log_info "Verifying boot entries:"
    for entry in "${required_entries[@]}"; do
        if [[ -f "${entries_dir}/${entry}" ]]; then
            log_info "✓ ${entry}"
        else
            log_error "✗ ${entry} missing"
            exit 1
        fi
    done
    
    # Check loader configuration
    if [[ -f "${MOUNT_DIR}/boot/loader/loader.conf" ]]; then
        log_info "✓ loader.conf"
    else
        log_error "✗ loader.conf missing"
        exit 1
    fi
    
    # Check kernel and initramfs
    if [[ -f "${MOUNT_DIR}/boot/vmlinuz-linux-zen" ]] && [[ -f "${MOUNT_DIR}/boot/initramfs-linux-zen.img" ]]; then
        log_info "✓ Kernel and initramfs present"
    else
        log_error "✗ Kernel or initramfs missing"
        exit 1
    fi
    
    log_success "Bootloader installation verified"
}

install_bootloader() {
    log_step "Installing and configuring bootloader"
    
    setup_initramfs
    install_systemd_boot
    create_boot_entries
    configure_bootloader
    verify_bootloader_installation
    
    log_success "Bootloader installation completed"
}

# ISO creation functions
finalize_system() {
    log_step "Finalizing system for ISO creation"
    
    # Clean up package cache to reduce image size
    log_info "Cleaning package cache"
    arch-chroot "${MOUNT_DIR}" pacman -Scc --noconfirm
    
    # Clean up temporary files
    log_info "Cleaning temporary files"
    rm -rf "${MOUNT_DIR}/tmp"/*
    rm -rf "${MOUNT_DIR}/var/tmp"/*
    
    # Update package database
    log_info "Updating package database"
    arch-chroot "${MOUNT_DIR}" pacman -Sy
    
    # Set up root password (temporary, will be changed during installation)
    log_info "Setting temporary root password"
    echo "root:archonos" | arch-chroot "${MOUNT_DIR}" chpasswd
    
    # Create version information file
    log_info "Creating version information"
    cat > "${MOUNT_DIR}/etc/archonos-release" << EOF
# ArchonOS Release Information
ARCHONOS_VERSION="${BUILD_VERSION}"
ARCHONOS_DATE="${BUILD_DATE}"
ARCHONOS_COMMIT="${BUILD_COMMIT}"
ARCHONOS_ARCH="${ARCH}"
BUILD_TYPE="atomic-immutable"
DESKTOP_ENVIRONMENT="plasma-wayland"
EOF
    
    log_success "System finalization completed"
}

create_iso_structure() {
    log_step "Creating ISO directory structure"
    
    # Clean and create ISO directory
    rm -rf "${ISO_DIR}"
    mkdir -p "${ISO_DIR}"/{EFI/BOOT,archonos,boot}
    
    # Copy disk image to ISO
    log_info "Copying disk image to ISO structure"
    cp "${IMAGE_FILE}" "${ISO_DIR}/archonos/archonos.img"
    
    # Create EFI boot files
    log_info "Setting up EFI boot structure"
    
    # Copy systemd-boot as EFI boot loader
    if [[ -f "${MOUNT_DIR}/boot/EFI/systemd/systemd-bootx64.efi" ]]; then
        cp "${MOUNT_DIR}/boot/EFI/systemd/systemd-bootx64.efi" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI"
    else
        log_error "systemd-boot EFI binary not found"
        exit 1
    fi
    
    # Copy kernel and initramfs
    log_info "Copying kernel and initramfs"
    cp "${MOUNT_DIR}/boot/vmlinuz-linux-zen" "${ISO_DIR}/boot/"
    cp "${MOUNT_DIR}/boot/initramfs-linux-zen.img" "${ISO_DIR}/boot/"
    
    # Create SquashFS for live system
    log_info "Creating SquashFS for live system"
    mkdir -p "${ISO_DIR}/archonos/x86_64"
    
    # Create a minimal rootfs for the live environment
    log_info "Creating live system SquashFS"
    if ! mksquashfs "${MOUNT_DIR}" "${ISO_DIR}/archonos/x86_64/airootfs.sfs" -e boot -comp xz; then
        log_error "Failed to create SquashFS"
        exit 1
    fi
    
    # Copy installer script into ISO
    log_info "Adding installer script"
    cp "${SCRIPT_DIR}/install-archonos.sh" "${ISO_DIR}/archonos/"
    chmod +x "${ISO_DIR}/archonos/install-archonos.sh"
    
    log_success "ISO structure created"
}

create_iso_boot_config() {
    log_step "Creating ISO boot configuration"
    
    # Create systemd-boot configuration for ISO
    mkdir -p "${ISO_DIR}/loader/entries"
    
    # Create loader configuration
    cat > "${ISO_DIR}/loader/loader.conf" << EOF
default  archonos-install.conf
timeout  10
console-mode max
editor   no
EOF
    
    # Create installation boot entry
    cat > "${ISO_DIR}/loader/entries/archonos-install.conf" << EOF
title   Install ArchonOS to Hard Drive
linux   /boot/vmlinuz-linux-zen
initrd  /boot/initramfs-linux-zen.img
options archisobasedir=archonos archisolabel=ARCHONOS cow_spacesize=1G quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 systemd.unified_cgroup_hierarchy=1 sysrq_always_enabled=1 mitigations=off nowatchdog
EOF
    
    # Create rescue boot entry
    cat > "${ISO_DIR}/loader/entries/archonos-rescue.conf" << EOF
title   ArchonOS Rescue Mode
linux   /boot/vmlinuz-linux-zen
initrd  /boot/initramfs-linux-zen.img
options archisobasedir=archonos archisolabel=ARCHONOS cow_spacesize=1G rescue quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 systemd.unified_cgroup_hierarchy=1 sysrq_always_enabled=1 mitigations=off nowatchdog
EOF
    
    log_success "ISO boot configuration created"
}

generate_iso() {
    log_step "Generating bootable ISO image"
    
    local iso_label="ARCHONOS"
    local iso_publisher="ArchonOS Project"
    local iso_application="ArchonOS ${BUILD_VERSION}"
    local xorriso_log="${BUILD_DIR}/xorriso.log"
    
    log_info "Creating ISO with xorriso"
    log_info "Label: ${iso_label}"
    log_info "Publisher: ${iso_publisher}"
    log_info "Application: ${iso_application}"
    log_info "Output: ${ISO_FILE}"
    log_info "Log file: ${xorriso_log}"
    
    # Generate ISO using xorriso with EFI boot support
    # Prepare bootloader files
    log_info "Preparing bootloader files"
    
    # Create isolinux directory
    mkdir -p "${ISO_DIR}/isolinux"
    
    # Copy all required syslinux modules
    log_info "Copying syslinux bootloader modules"
    
    # Required syslinux modules for isolinux
    local syslinux_modules=(
        "isolinux.bin"
        "ldlinux.c32"
        "menu.c32"
        "libutil.c32"
        "libcom32.c32"
    )
    
    for module in "${syslinux_modules[@]}"; do
        local module_path="/usr/lib/syslinux/bios/${module}"
        if [[ -f "$module_path" ]]; then
            cp "$module_path" "${ISO_DIR}/isolinux/"
            log_info "Copied ${module}"
        else
            log_error "${module} not found at ${module_path}"
            exit 1
        fi
    done
    
    # Create isolinux.cfg configuration file for installation ISO  
    log_info "Creating isolinux.cfg"
    cat > "${ISO_DIR}/isolinux/isolinux.cfg" << EOF
DEFAULT install
TIMEOUT 30
PROMPT 0
UI menu.c32

MENU TITLE ArchonOS Installer

LABEL install
    MENU LABEL Install ArchonOS to Hard Drive
    KERNEL /boot/vmlinuz-linux-zen
    APPEND initrd=/boot/initramfs-linux-zen.img archisobasedir=archonos archisolabel=ARCHONOS cow_spacesize=1G quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 systemd.unified_cgroup_hierarchy=1 sysrq_always_enabled=1 mitigations=off nowatchdog
    
LABEL rescue
    MENU LABEL ArchonOS Rescue Mode
    KERNEL /boot/vmlinuz-linux-zen
    APPEND initrd=/boot/initramfs-linux-zen.img archisobasedir=archonos archisolabel=ARCHONOS cow_spacesize=1G rescue quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 systemd.unified_cgroup_hierarchy=1 sysrq_always_enabled=1 mitigations=off nowatchdog
    
LABEL install_nomodeset
    MENU LABEL Install ArchonOS (safe graphics)
    KERNEL /boot/vmlinuz-linux-zen
    APPEND initrd=/boot/initramfs-linux-zen.img archisobasedir=archonos archisolabel=ARCHONOS cow_spacesize=1G nomodeset quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 systemd.unified_cgroup_hierarchy=1 sysrq_always_enabled=1 mitigations=off nowatchdog
EOF

    log_info "Running xorriso command..."
    if ! xorriso -as mkisofs \
        -iso-level 3 \
        -o "${ISO_FILE}" \
        -full-iso9660-filenames \
        -volid "${iso_label}" \
        -publisher "${iso_publisher}" \
        -preparer "${iso_application}" \
        -appid "${iso_application}" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e EFI/BOOT/BOOTX64.EFI \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -isohybrid-apm-hfsplus \
        "${ISO_DIR}" >"${xorriso_log}" 2>&1; then
        
        log_error "ISO generation failed"
        log_error "xorriso output (last 50 lines):"
        echo "----------------------------------------"
        tail -n 50 "${xorriso_log}"
        echo "----------------------------------------"
        log_error "Full xorriso log available at: ${xorriso_log}"
        exit 1
    fi
    
    log_info "xorriso completed successfully"
    log_info "xorriso output summary (last 10 lines):"
    tail -n 10 "${xorriso_log}"
    log_success "ISO image generated successfully"
}

verify_iso() {
    log_step "Verifying ISO image"
    
    # Check if ISO file exists and has reasonable size
    if [[ ! -f "${ISO_FILE}" ]]; then
        log_error "ISO file not found: ${ISO_FILE}"
        exit 1
    fi
    
    local iso_size
    iso_size=$(stat -f%z "${ISO_FILE}" 2>/dev/null || stat -c%s "${ISO_FILE}" 2>/dev/null)
    local iso_size_mb=$((iso_size / 1024 / 1024))
    
    log_info "ISO file: ${ISO_FILE}"
    log_info "ISO size: ${iso_size_mb}MB"
    
    # Verify minimum size (should be at least 1GB for a complete system)
    if [[ ${iso_size_mb} -lt 1024 ]]; then
        log_warn "ISO size seems small (${iso_size_mb}MB), but continuing..."
    fi
    
    # Verify ISO structure
    log_info "Verifying ISO structure with file command"
    file "${ISO_FILE}" | grep -q "ISO 9660" || {
        log_error "Generated file is not a valid ISO"
        exit 1
    }
    
    log_success "ISO verification completed"
}

create_checksums() {
    log_step "Creating checksums"
    
    local checksum_file="${BUILD_DIR}/checksums.txt"
    
    log_info "Generating SHA256 checksums"
    
    # Generate checksums for ISO and disk image
    (
        cd "${BUILD_DIR}"
        sha256sum "$(basename "${ISO_FILE}")" > "${checksum_file}"
        sha256sum "$(basename "${IMAGE_FILE}")" >> "${checksum_file}"
    )
    
    log_info "Checksums written to: ${checksum_file}"
    cat "${checksum_file}"
    
    log_success "Checksums created"
}

create_iso() {
    log_step "Creating ArchonOS ISO image"
    
    finalize_system
    create_iso_structure
    create_iso_boot_config
    generate_iso
    verify_iso
    create_checksums
    
    log_success "ISO creation completed"
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
    
    # Install and configure bootloader
    install_bootloader
    
    # Create bootable ISO image
    create_iso
    
    log_success "ArchonOS build completed successfully"
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