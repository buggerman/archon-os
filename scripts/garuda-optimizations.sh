#!/bin/bash
#
# Garuda Linux System Optimizations - Exact Copy
# This script implements all of Garuda's performance tweaks and optimizations
#

# Strict error handling
set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[GARUDA-INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[GARUDA-SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[GARUDA-WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[GARUDA-ERROR]${NC} $*" >&2
}

log_step() {
    echo -e "\n${BLUE}[GARUDA-STEP]${NC} $*" >&2
}

# Garuda's exact sysctl performance tweaks
configure_sysctl_performance() {
    log_step "Configuring Garuda's sysctl performance tweaks"
    
    # Create Garuda's exact sysctl configuration
    cat > /etc/sysctl.d/99-sysctl-performance-tweaks.conf << 'EOF'
# Garuda Linux Performance Tweaks
# These are Garuda's exact performance optimizations

# Memory management
vm.swappiness = 10
vm.vfs_cache_pressure = 65
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

# Network optimizations
net.core.rmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_default = 1048576
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 8192

# TCP optimizations
net.ipv4.tcp_rmem = 4096 1048576 2097152
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_probes = 60
net.ipv4.tcp_keepalive_intvl = 10

# Kernel optimizations
kernel.sched_autogroup_enabled = 1
kernel.sched_child_runs_first = 0
kernel.sched_latency_ns = 4000000
kernel.sched_migration_cost_ns = 50000
kernel.sched_min_granularity_ns = 500000
kernel.sched_wakeup_granularity_ns = 1000000
kernel.sched_compat_yield = 1
kernel.sched_rr_timeslice_ms = 3
kernel.sched_rt_period_us = 1000000
kernel.sched_rt_runtime_us = 950000

# Security vs Performance balance
kernel.yama.ptrace_scope = 1
kernel.kptr_restrict = 1
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 1

# File system optimizations
fs.file-max = 2097152
fs.nr_open = 1048576
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# Gaming optimizations
vm.max_map_count = 2147483642
dev.i915.perf_stream_paranoid = 0
EOF

    log_success "Garuda sysctl optimizations configured"
}

# Configure Garuda's I/O scheduler optimizations
configure_io_scheduler() {
    log_step "Configuring Garuda's I/O scheduler optimizations"
    
    # Create udev rules for I/O scheduler optimization
    cat > /etc/udev/rules.d/60-ioschedulers.rules << 'EOF'
# Garuda Linux I/O Scheduler Optimizations
# Set optimal I/O schedulers for different storage devices

# NVMe SSD - use none (no scheduler)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"

# SATA SSD - use mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"

# HDD - use bfq
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"

# MMC/SD - use bfq
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/scheduler}="bfq"

# Virtual block devices - use none
ACTION=="add|change", KERNEL=="vd[a-z]", ATTR{queue/scheduler}="none"
EOF

    log_success "Garuda I/O scheduler optimizations configured"
}

# Configure CPU governor for performance
configure_cpu_governor() {
    log_step "Configuring Garuda's CPU governor settings"
    
    # Create systemd service for CPU governor
    cat > /etc/systemd/system/garuda-cpu-performance.service << 'EOF'
[Unit]
Description=Garuda CPU Performance Governor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo performance > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
ExecStart=/bin/bash -c 'echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo' 
ExecStart=/bin/bash -c 'echo 1 > /sys/devices/system/cpu/cpufreq/boost'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable garuda-cpu-performance.service
    
    log_success "Garuda CPU governor configured"
}

# Configure Garuda's gaming optimizations
configure_gaming_optimizations() {
    log_step "Configuring Garuda's gaming optimizations"
    
    # Create gaming optimization service
    cat > /etc/systemd/system/garuda-gaming-tweaks.service << 'EOF'
[Unit]
Description=Garuda Gaming Performance Tweaks
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/bash -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
ExecStart=/bin/bash -c 'echo 0 > /proc/sys/kernel/split_lock_mitigate'
ExecStart=/bin/bash -c 'echo 1 > /proc/sys/vm/compaction_proactiveness'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable garuda-gaming-tweaks.service
    
    # Configure gaming udev rules
    cat > /etc/udev/rules.d/99-garuda-gaming.rules << 'EOF'
# Garuda Gaming Device Optimizations
# Disable power management for gaming peripherals

# Gaming mice
SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{power/autosuspend}="-1"
SUBSYSTEM=="usb", ATTR{idVendor}=="1532", ATTR{power/autosuspend}="-1"
SUBSYSTEM=="usb", ATTR{idVendor}=="1038", ATTR{power/autosuspend}="-1"
SUBSYSTEM=="usb", ATTR{idVendor}=="0738", ATTR{power/autosuspend}="-1"

# Gaming keyboards
SUBSYSTEM=="usb", ATTR{idVendor}=="1e7d", ATTR{power/autosuspend}="-1"
SUBSYSTEM=="usb", ATTR{idVendor}=="04d9", ATTR{power/autosuspend}="-1"

# Gaming controllers
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{power/autosuspend}="-1"
SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{power/autosuspend}="-1"

# HID devices
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", MODE="0664", GROUP="input", TAG+="uaccess"
EOF

    log_success "Garuda gaming optimizations configured"
}

# Configure Garuda's ZRAM setup
configure_zram() {
    log_step "Configuring Garuda's ZRAM setup"
    
    # Create Garuda's ZRAM configuration
    cat > /etc/systemd/zram-generator.conf << 'EOF'
# Garuda Linux ZRAM Configuration
[zram0]
zram-fraction = 0.25
max-zram-size = 2048
compression-algorithm = zstd
swap-priority = 32767
EOF

    log_success "Garuda ZRAM configuration created"
}

# Configure Snapper for automatic snapshots
configure_snapper() {
    log_step "Configuring Snapper automatic snapshots"
    
    # Create Snapper configuration for root
    snapper -c root create-config /
    
    # Configure Snapper for automatic snapshots
    cat > /etc/snapper/configs/root << 'EOF'
# Snapper configuration for root filesystem
SUBVOLUME="/"
FSYSTEM="btrfs"
TYPE="single"
FORMAT="btrfs"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
TIMELINE_MIN_AGE="1800"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
EOF
    
    # Enable snapper services
    systemctl enable snapper-timeline.timer
    systemctl enable snapper-cleanup.timer
    
    log_success "Snapper configuration created"
}

# Configure grub-btrfs for snapshot booting
configure_grub_btrfs() {
    log_step "Configuring grub-btrfs for snapshot booting"
    
    # Create grub-btrfs configuration
    mkdir -p /etc/default/grub-btrfs
    cat > /etc/default/grub-btrfs/config << 'EOF'
# grub-btrfs Configuration
GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION="false"
GRUB_BTRFS_MOUNT_POINT="/boot"
GRUB_BTRFS_MKCONFIG_LIB="/usr/share/grub/grub-mkconfig_lib"
GRUB_BTRFS_SCRIPT_CHECK="grub-script-check"
GRUB_BTRFS_LIMIT="10"
GRUB_BTRFS_SUBVOLUME_SORT="descending"
GRUB_BTRFS_SHOW_SNAPSHOTS_FOUND="true"
GRUB_BTRFS_SHOW_TOTAL_SNAPSHOTS_FOUND="true"
GRUB_BTRFS_TITLE_FORMAT="Snapshot: %s"
GRUB_BTRFS_IGNORE_SPECIFIC_PATH=""
GRUB_BTRFS_IGNORE_PREFIX_PATH=""
GRUB_BTRFS_DIRNAME="snapshots"
GRUB_BTRFS_PROTECTION_AUTHORIZED_USERS=""
GRUB_BTRFS_DISABLE_BOOTING_READONLY_SNAPSHOTS="false"
EOF
    
    log_success "grub-btrfs configuration created"
}

# Main execution
main() {
    log_info "Starting Garuda Linux optimizations configuration"
    
    configure_sysctl_performance
    configure_io_scheduler
    configure_cpu_governor
    configure_gaming_optimizations
    configure_zram
    configure_snapper
    configure_grub_btrfs
    
    log_success "Garuda Linux optimizations configured successfully"
    log_info "Reboot required for all optimizations to take effect"
}

# Execute main function
main "$@"