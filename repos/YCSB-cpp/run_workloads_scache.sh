#!/bin/bash

set -e -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- Script-specific configuration ---
# WORKLOADS="ait"
# DB_NAME="${DB_NAME:-rocksdb}" # set to leveldb/sqlite to switch backend
CPU_AFFINITY="${CPU_AFFINITY:-0-24}"
BG_DISK_NUM="0:0"
REPORT_SYSTEM_CPU_USAGE=1
OUTPUT_DIR="${OUTPUT_DIR:-output/cpp_$(date +"%Y-%m-%d_%H-%M-%S")_scache}"
RUN_STATS_SUBDIR="${RUN_STATS_SUBDIR:-run_stats_tables_scache}"
SCACHE_NR_REGIONS="${SCACHE_NR_REGIONS:-80}"

load_common_config

# --- Scache pool management ---
scache_init() {
    echo "Initializing scache pool (nr_regions=$SCACHE_NR_REGIONS)..."
    write_sysfs "$SCACHE_NR_REGIONS" /sys/fs/sc_memory/nr_regions
    write_sysfs 1 /sys/fs/sc_memory/enabled
}

scache_uninit() {
    echo "Uninitializing scache pool..."
    write_sysfs 0 /sys/fs/sc_memory/enabled
}

# --- Scache-mode system configuration ---
configure_system() {
    local num_threads="$1"

    write_sysfs "$STAT_DISK_NUM" /sys/kernel/stats/stats_allowed_dev_name
    write_sysfs 0 "$STATS_FILE"
    write_sysfs "$BG_DISK_NUM" /sys/kernel/stats/bg_allowed_dev_name

    write_sysfs 0 /sys/fs/dsa_emu/dsa_emu_thread_numa
    write_sysfs 0 /sys/fs/dsa_emu/enable_bdp
    write_sysfs 0 /sys/fs/dsa_emu/force_node
    write_sysfs 0 /sys/fs/dsa_emu/force_node_nid
    write_sysfs 0 /sys/fs/dsa_emu/prefetch
    write_sysfs 0 /sys/fs/dsa_emu/no_zero_alloc
    write_sysfs 1 /proc/sys/kernel/numa_balancing

    write_sysfs "$num_threads" /sys/fs/dsa_emu/num_threads

    sleep 1
}

# --- Hook implementations ---
configure_for_load() { configure_system 0; }
configure_for_run()  {
    configure_system 0
    scache_init
}

run_ycsb() {
    local workload="$1"
    local -a run_cmd
    build_ycsb_command run "$workload" run_cmd
    run_ycsb_and_capture "${run_cmd[@]}"
}

post_run_hook() {
    scache_uninit
}

# --- Run ---
init_run
run_all_workloads
