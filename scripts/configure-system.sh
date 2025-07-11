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
    log_step "Configuring Flatpak (Garuda style)"
    
    log_info "Adding Flathub repository"
    
    # Add Flathub repository
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    
    # Install essential Flatpak applications (Garuda's selection)
    log_info "Installing essential Flatpak applications"
    flatpak install -y --noninteractive flathub org.mozilla.firefox
    flatpak install -y --noninteractive flathub org.videolan.VLC
    flatpak install -y --noninteractive flathub org.libreoffice.LibreOffice
    flatpak install -y --noninteractive flathub org.gimp.GIMP
    flatpak install -y --noninteractive flathub org.blender.Blender
    flatpak install -y --noninteractive flathub com.valvesoftware.Steam
    flatpak install -y --noninteractive flathub net.lutris.Lutris
    flatpak install -y --noninteractive flathub com.heroicgameslauncher.hgl
    flatpak install -y --noninteractive flathub com.discordapp.Discord
    flatpak install -y --noninteractive flathub com.spotify.Client
    flatpak install -y --noninteractive flathub org.audacityteam.Audacity
    flatpak install -y --noninteractive flathub org.kde.krita
    flatpak install -y --noninteractive flathub org.inkscape.Inkscape
    flatpak install -y --noninteractive flathub org.kde.kdenlive
    flatpak install -y --noninteractive flathub com.obsproject.Studio
    flatpak install -y --noninteractive flathub org.signal.Signal
    flatpak install -y --noninteractive flathub org.telegram.desktop
    flatpak install -y --noninteractive flathub com.github.tchx84.Flatseal
    flatpak install -y --noninteractive flathub org.gnome.baobab
    flatpak install -y --noninteractive flathub org.gnome.Calculator
    flatpak install -y --noninteractive flathub org.kde.ark
    flatpak install -y --noninteractive flathub org.kde.spectacle
    flatpak install -y --noninteractive flathub org.kde.gwenview
    flatpak install -y --noninteractive flathub org.kde.konsole
    flatpak install -y --noninteractive flathub org.kde.dolphin
    flatpak install -y --noninteractive flathub org.kde.kate
    
    log_success "Flatpak configuration completed"
}

install_linuxbrew() {
    log_step "Installing LinuxBrew"
    
    log_info "Installing LinuxBrew for CLI tools"
    
    # Create linuxbrew user
    useradd -m -s /bin/bash linuxbrew
    
    # Install LinuxBrew
    sudo -u linuxbrew bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    
    # Add LinuxBrew to PATH for all users
    echo 'export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"' >> /etc/profile
    echo 'export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"' >> /etc/bash.bashrc
    
    # Install essential CLI tools via LinuxBrew
    log_info "Installing essential CLI tools via LinuxBrew"
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install git
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install node
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install python
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install rust
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install go
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install neovim
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install bat
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install exa
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install fd
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install ripgrep
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install fzf
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install zoxide
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install starship
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install lazygit
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install docker
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install kubectl
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install terraform
    sudo -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install awscli
    
    log_success "LinuxBrew installation completed"
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


configure_snapshots() {
    log_step "Configuring Snapper snapshots"
    
    log_info "Setting up Snapper for automatic snapshots"
    
    # Configure Snapper for BTRFS snapshots
    # This will be handled by the optimizations script
    
    log_success "Snapper snapshot configuration completed"
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
    install_linuxbrew
    create_default_user
    configure_snapshots
    
    # Run system optimizations
    log_info "Running system optimizations"
    if [[ -f "/garuda-optimizations.sh" ]]; then
        /garuda-optimizations.sh
    fi
    
    # Add installer command to bashrc for easy access
    log_info "Setting up installer command alias"
    echo "alias install-archonos='sudo /usr/local/bin/install-archonos'" >> /home/archon/.bashrc
    echo "alias install='sudo /usr/local/bin/install-archonos'" >> /home/archon/.bashrc
    
    # Run desktop configuration
    log_info "Running desktop configuration"
    if [[ -f "/configure-desktop.sh" ]]; then
        /configure-desktop.sh
    fi
    
    log_success "ArchonOS system configuration completed successfully"
    log_info "System is ready for bootloader installation"
}

# Execute main function
main "$@"