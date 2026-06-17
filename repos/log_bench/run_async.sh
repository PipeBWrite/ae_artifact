#!/bin/bash
# run_async.sh - Run log4j2 benchmark under async kernel mode.

set -e -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- Script-specific configuration ---
BENCH_MODE="async"
CPU_AFFINITY="${CPU_AFFINITY:-8-11}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output/log4j2_$(date +"%Y-%m-%d_%H-%M-%S")_async}"

load_config

# BG_DISK_NUM uses the actual disk (set after load_config computes DISK_NUM)
BG_DISK_NUM="$DISK_NUM"

# --- Async-mode system configuration ---
configure_for_run() {
    write_sysfs "$STAT_DISK_NUM" /sys/kernel/stats/stats_allowed_dev_name
    write_sysfs "$BG_DISK_NUM" /sys/kernel/stats/bg_allowed_dev_name

    write_sysfs "${LOG4J_THREAD_NUMA:--1}" /sys/fs/dsa_emu/dsa_emu_thread_numa
    write_sysfs "${LOG4J_FORCE_NODE:-0}" /sys/fs/dsa_emu/force_node
    write_sysfs "${LOG4J_PREFETCH:-1}" /sys/fs/dsa_emu/prefetch
    write_sysfs "${LOG4J_NO_ZERO_ALLOC:-2}" /sys/fs/dsa_emu/no_zero_alloc
    write_sysfs 0 /proc/sys/kernel/numa_balancing
    write_sysfs 0 /sys/fs/dsa_emu/debug_bg_fsync
    local _folio_order="${LOG4J_FOLIO_ORDER:-}"
    if [[ -z "$_folio_order" ]]; then
        case "${CURRENT_FS_TYPE:-ext4}" in
            xfs) _folio_order=6 ;;
            *)   _folio_order=0 ;;
        esac
    fi
    write_sysfs "$_folio_order" /sys/fs/dsa_emu/folio_pool_order_max

    write_sysfs "${LOG4J_NUM_THREADS:-8}" /sys/fs/dsa_emu/num_threads

    sleep 1
}

post_run_hook() {
    if [[ "$USE_SUDO" == "1" ]]; then
        run_privileged cat /sys/kernel/stats/stats || true
    fi
    # Reduce threads between runs
    write_sysfs 1 /sys/fs/dsa_emu/num_threads
    write_sysfs 0 /sys/fs/dsa_emu/folio_pool_order_max
}

# --- Run ---
init_run
run_all_benchmarks
