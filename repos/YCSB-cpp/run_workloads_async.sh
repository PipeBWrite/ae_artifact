#!/bin/bash

set -e -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- Script-specific configuration ---
# WORKLOADS="ait"
# DB_NAME="${DB_NAME:-rocksdb}" # set to leveldb/sqlite to switch backend
CPU_AFFINITY="${CPU_AFFINITY:-8-32}"
OUTPUT_DIR="${OUTPUT_DIR:-output/cpp_$(date +"%Y-%m-%d_%H-%M-%S")_async}"
REPORT_SYSTEM_CPU_USAGE=1
RUN_STATS_SUBDIR="${RUN_STATS_SUBDIR:-run_stats_tables_async}"

load_common_config

# BG_DISK_NUM uses the actual disk (set after load_common_config computes DISK_NUM)
BG_DISK_NUM="$DISK_NUM"

# --- Async-mode system configuration ---
configure_system() {
    local num_threads="$1"
    local folio_pool_order_max=""

    write_sysfs "$STAT_DISK_NUM" /sys/kernel/stats/stats_allowed_dev_name
    write_sysfs 0 "$STATS_FILE"
    write_sysfs "$BG_DISK_NUM" /sys/kernel/stats/bg_allowed_dev_name

    write_sysfs 0 /sys/fs/dsa_emu/dsa_emu_thread_numa
    write_sysfs 0 /sys/fs/dsa_emu/force_node
    write_sysfs 1 /sys/fs/dsa_emu/prefetch
    write_sysfs 2 /sys/fs/dsa_emu/no_zero_alloc
    write_sysfs 1 /proc/sys/kernel/numa_balancing
    write_sysfs auto /sys/fs/dsa_emu/debug_bg_fsync
    write_sysfs 1048576 /sys/fs/dsa_emu/debug_dirty_threshold
    write_sysfs -1 /sys/fs/dsa_emu/dsa_emu_thread_numa
    write_sysfs 0 /sys/fs/dsa_emu/fg_bwb_all
    write_sysfs 0 /sys/fs/dsa_emu/bg_batch_handle
    write_sysfs 1 /sys/fs/dsa_emu/sfr_drain

    case "$FS_TYPE" in
        ext4) folio_pool_order_max="0" ;;
        xfs)  folio_pool_order_max="6" ;;
    esac
    if [[ -n "$folio_pool_order_max" ]]; then
        write_sysfs "$folio_pool_order_max" /sys/fs/dsa_emu/folio_pool_order_max
    fi

    write_sysfs "$num_threads" /sys/fs/dsa_emu/num_threads

    sleep 1
}

configure_system_orig() {
    configure_system "$1"
    write_sysfs -1 /sys/fs/dsa_emu/dsa_emu_thread_numa
    # write_sysfs "0:0" /sys/kernel/stats/bg_allowed_dev_name
}

# --- Hook implementations ---
configure_for_load() { configure_system_orig "8"; }
configure_for_run()  { configure_system "8"; }

run_ycsb() {
    local workload="$1"
    local -a run_cmd
    build_ycsb_command run "$workload" run_cmd
    run_ycsb_and_capture "${run_cmd[@]}"
}

post_run_hook() {
    if [[ "$USE_SUDO" == "1" ]]; then
        run_privileged cat /sys/kernel/stats/stats || true
    fi
    configure_system_orig 1
}

# --- Run ---
init_run
run_all_workloads
