#!/bin/bash
# Save as: prepare_for_benchmarking.sh
# Run with: sudo ./prepare_for_benchmarking.sh

set -e

# Configure OpenMP and stack limit
export OMP_NUM_THREADS=1
export OMP_THREAD_LIMIT=1
ulimit -s unlimited

# Disable Hyper-Threading
echo off > /sys/devices/system/cpu/smt/control

# Disable Turbo Boost
if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
    # 0 disables boost for some drivers (e.g., intel_cpufreq, amd_pstate)
    echo 0 > /sys/devices/system/cpu/cpufreq/boost
else
    # Fallback: disable turbo via MSR 0x1A0 (bit 38)
    wrmsr -a 0x1a0 0x4000850089
    # Set frequency to 2400MHz via MSR 0x199
    wrmsr -a 0x199 0x1800
fi

# Set performance governor and fixed frequency (adjust MHz as needed)
TARGET_MHZ=2400
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    cpupower frequency-set -g performance
    cpupower frequency-set -d ${TARGET_MHZ}MHz -u ${TARGET_MHZ}MHz
else
    if command -v wrmsr >/dev/null 2>&1; then
        modprobe msr 2>/dev/null || true
        ratio=$((TARGET_MHZ / 100))
        perf_ctl=$((ratio << 8))
        printf -v perf_ctl_hex "0x%x" "$perf_ctl"
        wrmsr -a 0x199 "$perf_ctl_hex"
        wrmsr -a 0x774 0x181818
        wrmsr -a 0x620 0x1818
        echo "cpufreq not available; set IA32_PERF_CTL to ratio ${ratio} via MSR." >&2
    else
        echo "cpufreq not available and wrmsr missing; cannot lock frequency." >&2
    fi
fi

# Disable thermal throttling
sudo systemctl stop thermald

# Disable watchdogs (persist so insmod doesn't fail with EBUSY after a reboot --
# the NMI watchdog reserves PMC0, blocking reserve_perfctr_nmi in the module).
sudo sysctl -w kernel.watchdog=0
sudo sysctl -w kernel.nmi_watchdog=0
if ! grep -q "^kernel.watchdog=0" /etc/sysctl.conf; then
    echo "kernel.watchdog=0" | sudo tee -a /etc/sysctl.conf >/dev/null
fi
if ! grep -q "^kernel.nmi_watchdog=0" /etc/sysctl.conf; then
    echo "kernel.nmi_watchdog=0" | sudo tee -a /etc/sysctl.conf >/dev/null
fi

# Disable ASLR so per-run cache placement is deterministic (otherwise
# L1D_REPLACEMENT / L1I_MISS counts wobble run-to-run as code/data land
# on different cache sets each invocation).
sudo sysctl -w kernel.randomize_va_space=0

# Allow perf_event_open for non-root (persists via sysctl.conf)
sudo sysctl -w kernel.perf_event_paranoid=-1
if ! grep -q "^kernel.perf_event_paranoid=-1" /etc/sysctl.conf; then
    echo "kernel.perf_event_paranoid=-1" | sudo tee -a /etc/sysctl.conf >/dev/null
fi

# Give collector binary perf capability (persists across reboot)
if [ -x "./simpoint_perf_collector" ]; then
    sudo setcap cap_perfmon,cap_sys_admin=eip ./simpoint_perf_collector || true
fi

# Stop unnecessary services
sudo systemctl stop snapd cups bluetooth avahi-daemon 2>/dev/null || true
# sudo systemctl stop NetworkManager ModemManager 2>/dev/null || true
sudo systemctl stop packagekit update-notifier 2>/dev/null || true

# Drop filesystem caches
sync
echo 3 > /proc/sys/vm/drop_caches

echo "System prepared for benchmarking"
