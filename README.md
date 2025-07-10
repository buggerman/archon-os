# ArchonOS

> An atomic, immutable Arch Linux distribution designed for reliability and security

[![Build Status](https://github.com/buggerman/archon-os/actions/workflows/build.yml/badge.svg)](https://github.com/buggerman/archon-os/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/buggerman/archon-os)](https://github.com/buggerman/archon-os/releases)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

ArchonOS is a modern Linux distribution built on Arch Linux that implements atomic updates and an immutable root filesystem. It combines the cutting-edge nature of Arch with the reliability and security of immutable systems.

## 🚀 Key Features

### 🔒 Immutable Root Filesystem
- **Read-only system partition** prevents accidental corruption and unauthorized modifications
- **System integrity** guaranteed through mount-time verification
- **Rollback protection** ensures system stability

### ⚛️ Atomic A/B Updates
- **Zero-downtime updates** with instant switching between system versions
- **Automatic rollback** on boot failure or system corruption
- **Btrfs subvolumes** enable efficient space usage and instant switching
- **Update safety** with complete transaction-like update process

### 🖥️ Modern Desktop Environment
- **KDE Plasma on Wayland** for the latest desktop technology
- **SDDM display manager** with Wayland session support
- **Hardware acceleration** and modern graphics stack
- **Minimal core** with essential applications only

### 📦 Application Isolation
- **Flatpak integration** for GUI applications with sandboxing
- **Flathub repository** pre-configured for easy app installation
- **LinuxBrew support** for CLI tools and development environments
- **Clear separation** between system and user applications

### 🛠️ Advanced Filesystem
- **Btrfs with compression** (zstd) for space efficiency
- **Subvolume architecture** for atomic operations
- **Snapshot capabilities** for system recovery
- **Space-efficient** incremental updates

### 🚀 Modern Boot System
- **systemd-boot** for fast, secure UEFI booting
- **A/B boot entries** for seamless system switching
- **Recovery options** with fallback initramfs
- **Secure boot ready** for enhanced security

## 📥 Download & Installation

### System Requirements
- **UEFI-capable system** (Legacy BIOS not supported)
- **4GB RAM minimum** (8GB recommended)
- **20GB storage minimum** (40GB recommended)
- **x86_64 processor** (64-bit)

### Download
1. Visit the [Releases page](https://github.com/buggerman/archon-os/releases)
2. Download the latest `archonos-*.iso` file
3. Download `checksums.txt` for verification

### Verification
```bash
# Verify download integrity
sha256sum -c checksums.txt
```

### Installation
1. **Flash to USB**: Use `dd`, Rufus, or similar tool
   ```bash
   sudo dd if=archonos-*.iso of=/dev/sdX bs=4M status=progress
   ```
2. **Boot from USB**: Select USB device in UEFI firmware
3. **Follow installer**: Guided installation process
4. **First boot**: Change default passwords when prompted

## 🏗️ Build System

ArchonOS uses a fully automated CI/CD pipeline powered by GitHub Actions.

### Architecture Overview
```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   GitHub Repo   │ -> │  GitHub Actions  │ -> │   Releases      │
│                 │    │                  │    │                 │
│ • Build Scripts │    │ • Arch Container │    │ • ISO Files     │
│ • Configuration │    │ • Automated Build│    │ • Checksums     │
│ • Workflows     │    │ • Testing        │    │ • Artifacts     │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

### Build Process
1. **Environment Setup**: Arch Linux container with build tools
2. **Disk Preparation**: GPT partition table with EFI and Btrfs
3. **Subvolume Creation**: A/B layout (@os_a, @os_b, @home, @log, @swap)
4. **System Installation**: Minimal package set via pacstrap
5. **Configuration**: System settings, services, and users
6. **Bootloader Setup**: systemd-boot with A/B entries
7. **ISO Generation**: Bootable installation media creation

### Local Building
```bash
# Clone repository
git clone https://github.com/buggerman/archon-os.git
cd archon-os

# Run build (requires Arch Linux)
sudo ./scripts/build.sh
```

## 🔧 System Architecture

### Filesystem Layout
```
/                    # @os_a subvolume (read-only)
├── boot/           # EFI system partition (FAT32)
├── home/           # @home subvolume (read-write)
├── var/log/        # @log subvolume (read-write)
├── swap/           # @swap subvolume (read-write)
├── tmp/            # tmpfs (memory)
└── var/tmp/        # tmpfs (memory)
```

### Update Process
```
Current System (@os_a) ──┐
                        │
                        ├── Update Available
                        │
                        └── Download to @os_b
                            │
                            ├── Verification
                            │
                            ├── Switch Boot Entry
                            │
                            └── Reboot to @os_b
```

### Package Management
- **System packages**: Managed atomically via updates
- **GUI applications**: Installed via Flatpak
- **CLI tools**: Installed via LinuxBrew
- **Development**: Containers or virtual environments

## 👥 Default Users

| User     | Password  | Purpose                          |
|----------|-----------|----------------------------------|
| `archon` | `archon`  | Default user (change required)   |
| `root`   | `archonos`| System admin (change on install) |

**Security Note**: All default passwords must be changed on first login.

## 🛡️ Security Features

- **Immutable root**: Prevents unauthorized system modifications
- **Verified boot**: systemd-boot with secure boot capability
- **Application sandboxing**: Flatpak provides application isolation
- **Minimal attack surface**: Limited package set in base system
- **Atomic updates**: Reduces exposure to partial system states

## 🤝 Contributing

We welcome contributions! Please see our [contributing guidelines](CONTRIBUTING.md) for details.

### Development Workflow
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test the build locally
5. Submit a pull request

### Reporting Issues
- Use the [GitHub Issues](https://github.com/buggerman/archon-os/issues) page
- Include system information and logs
- Describe reproduction steps clearly

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Arch Linux**: Foundation and package ecosystem
- **Btrfs**: Advanced filesystem capabilities
- **KDE Project**: Desktop environment
- **Flatpak**: Application sandboxing technology
- **systemd**: Modern init system and boot manager

---

**ArchonOS**: *Reliable. Secure. Atomic.*