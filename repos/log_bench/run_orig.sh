#!/bin/bash
# run_orig.sh - Run log4j2 benchmark under orig (synchronous) kernel mode.

set -e -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- Script-specific configuration ---
BENCH_MODE="orig"
CPU_AFFINITY="${CPU_AFFINITY:-8-11}"
BG_DISK_NUM="0:0"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output/log4j2_$(date +"%Y-%m-%d_%H-%M-%S")_orig}"

load_config

# --- Orig-mode system configuration ---
configure_for_run() {
    write_sysfs "$STAT_DISK_NUM" /sys/kernel/stats/stats_allowed_dev_name
    write_sysfs "$BG_DISK_NUM" /sys/kernel/stats/bg_allowed_dev_name

    write_sysfs 0 /sys/fs/dsa_emu/dsa_emu_thread_numa
    write_sysfs 0 /sys/fs/dsa_emu/force_node
    write_sysfs 0 /sys/fs/dsa_emu/prefetch
    write_sysfs 0 /sys/fs/dsa_emu/no_zero_alloc
    write_sysfs 0 /proc/sys/kernel/numa_balancing

    write_sysfs 0 /sys/fs/dsa_emu/num_threads

    sleep 1
}

# --- Run ---
init_run
run_all_benchmarks
