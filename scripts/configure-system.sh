#!/bin/bash
#
# ArchonOS System Configuration Script
# Executed within arch-chroot to configure the installed system
#
# This script handles:
# - Hostname and network configuration
# - Locale and timezone setup
# - Service enablement
# - User and security configuration
#

# Strict error handling
set -euo pipefail

# Configuration parameters (will be set by main build script)
HOSTNAME="${HOSTNAME:-archonos}"
TIMEZONE="${TIMEZONE:-UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[CONFIG-INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[CONFIG-SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[CONFIG-WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[CONFIG-ERROR]${NC} $*" >&2
}

log_step() {
    echo -e "\n${BLUE}[CONFIG-STEP]${NC} $*" >&2
}

# System configuration functions
configure_hostname() {
    log_step "Configuring hostname"
    
    log_info "Setting hostname to: ${HOSTNAME}"
    echo "${HOSTNAME}" > /etc/hostname
    
    # Configure hosts file
    log_info "Configuring /etc/hosts"
    cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
    
    log_success "Hostname configured successfully"
}

configure_locale() {
    log_step "Configuring locale and language"
    
    log_info "Setting locale to: ${LOCALE}"
    
    # Generate locales
    log_info "Generating locales"
    echo "${LOCALE} UTF-8" >> /etc/locale.gen
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    
    # Set system locale
    echo "LANG=${LOCALE}" > /etc/locale.conf
    
    # Set keymap
    log_info "Setting keymap to: ${KEYMAP}"
    echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
    
    log_success "Locale configuration completed"
}

configure_timezone() {
    log_step "Configuring timezone"
    
    log_info "Setting timezone to: ${TIMEZONE}"
    
    # Set timezone
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    
    # Generate /etc/adjtime
    hwclock --systohc
    
    log_success "Timezone configured successfully"
}

configure_pacman() {
    log_step "Configuring package manager"
    
    log_info "Enabling parallel downloads and color output"
    
    # Enable parallel downloads and color
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf
    sed -i 's/#Color/Color/' /etc/pacman.conf
    
    # Enable multilib (for 32-bit support)
    log_info "Enabling multilib repository"
    if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
        echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    fi
    
    log_success "Pacman configuration completed"
}

enable_services() {
    log_step "Enabling essential services"
    
    # Essential services for ArchonOS
    local services=(
        "sddm.service"           # Display manager
        "NetworkManager.service" # Network management
        "bluetooth.service"      # Bluetooth support
        "systemd-timesyncd.service" # Time synchronization
    )
    
    log_info "Enabling services:"
    for service in "${services[@]}"; do
        log_info "  - ${service}"
        systemctl enable "${service}"
    done
    
    # Configure SDDM for Wayland
    log_info "Configuring SDDM for Wayland session"
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/wayland.conf << EOF
[General]
DisplayServer=wayland

[Wayland]
SessionDir=/usr/share/wayland-sessions
EOF
    
    log_success "Services enabled successfully"
}

configure_sudo() {
    log_step "Configuring sudo"
    
    log_info "Setting up sudo configuration"
    
    # Allow wheel group to use sudo
    echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
    
    # Set secure permissions
    chmod 440 /etc/sudoers.d/wheel
    
    log_success "Sudo configuration completed"
}

configure_flatpak() {
    log_step "Configuring Flatpak"
    
    log_info "Adding Flathub repository"
    
    # Add Flathub repository
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    
    log_success "Flatpak configuration completed"
}

create_default_user() {
    log_step "Creating default user account"
    
    local username="archon"
    
    log_info "Creating user: ${username}"
    
    # Create user with home directory
    useradd -m -G wheel,audio,video,optical,storage -s /bin/bash "${username}"
    
    # Set default password (will be changed on first login)
    echo "${username}:archon" | chpasswd
    
    # Force password change on first login
    chage -d 0 "${username}"
    
    log_info "Default user '${username}' created (password must be changed on first login)"
    log_success "User configuration completed"
}

configure_immutable_root() {
    log_step "Configuring immutable root filesystem"
    
    log_info "Setting up read-only root filesystem configuration"
    
    # Create systemd mount override for read-only root
    mkdir -p /etc/systemd/system/-.mount.d
    cat > /etc/systemd/system/-.mount.d/readonly.conf << EOF
[Mount]
Options=ro,noatime,compress=zstd:1,space_cache=v2,subvol=@os_a
EOF
    
    log_info "Root filesystem will be mounted read-only on next boot"
    log_success "Immutable root configuration completed"
}

# Main configuration execution
main() {
    log_info "Starting ArchonOS system configuration"
    
    configure_hostname
    configure_locale
    configure_timezone
    configure_pacman
    enable_services
    configure_sudo
    configure_flatpak
    create_default_user
    configure_immutable_root
    
    # Add installer command to bashrc for easy access
    log_info "Setting up installer command alias"
    echo "alias install-archonos='sudo /usr/local/bin/install-archonos'" >> /home/archon/.bashrc
    echo "alias install='sudo /usr/local/bin/install-archonos'" >> /home/archon/.bashrc
    
    log_success "ArchonOS system configuration completed successfully"
    log_info "System is ready for bootloader installation"
}

# Execute main function
main "$@"