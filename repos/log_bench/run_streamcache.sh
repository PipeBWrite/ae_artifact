#!/bin/bash
# run_streamcache.sh - Run log4j2 benchmark under streamcache kernel mode.

set -e -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- Script-specific configuration ---
BENCH_MODE="streamcache"
CPU_AFFINITY="${CPU_AFFINITY:-8-11}"
BG_DISK_NUM="0:0"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output/log4j2_$(date +"%Y-%m-%d_%H-%M-%S")_streamcache}"
SCACHE_NR_REGIONS="${SCACHE_NR_REGIONS:-80}"

load_config

# --- Streamcache pool management ---
streamcache_init() {
    echo "Initializing streamcache pool (nr_regions=$SCACHE_NR_REGIONS)..."
    write_sysfs "$SCACHE_NR_REGIONS" /sys/fs/sc_memory/nr_regions
    write_sysfs 1 /sys/fs/sc_memory/enabled
}

streamcache_uninit() {
    echo "Uninitializing streamcache pool..."
    write_sysfs 0 /sys/fs/sc_memory/enabled
}

# --- Streamcache-mode system configuration ---
configure_for_run() {
    write_sysfs "$STAT_DISK_NUM" /sys/kernel/stats/stats_allowed_dev_name
    write_sysfs "$BG_DISK_NUM" /sys/kernel/stats/bg_allowed_dev_name

    write_sysfs 0 /sys/fs/dsa_emu/dsa_emu_thread_numa
    write_sysfs 0 /sys/fs/dsa_emu/enable_bdp
    write_sysfs 0 /sys/fs/dsa_emu/force_node
    write_sysfs 0 /sys/fs/dsa_emu/force_node_nid
    write_sysfs 0 /sys/fs/dsa_emu/prefetch
    write_sysfs 0 /sys/fs/dsa_emu/no_zero_alloc
    write_sysfs 1 /proc/sys/kernel/numa_balancing

    write_sysfs 0 /sys/fs/dsa_emu/num_threads

    streamcache_init
    sleep 1
}

post_run_hook() {
    streamcache_uninit
}

# --- Run ---
init_run
run_all_benchmarks
