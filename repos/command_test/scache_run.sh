#!/bin/bash

set -euo pipefail

use_perf="${use_perf:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AE_ROOT="${AE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LINUX_DIR="${LINUX_DIR:-$HOME/linux}"
DEVICE="${DEVICE:-/dev/nvme0n1}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/pmem}"
TEST_PATH="${TEST_PATH:-$AE_ROOT/results/command_scache}"
CPU_AFFINITY="${CPU_AFFINITY:-40}"
STAT_DISK_NUM="${STAT_DISK_NUM:-259:0}"
BG_DISK_NUM="${BG_DISK_NUM:-0:0}"
SCACHE_NR_REGIONS="${SCACHE_NR_REGIONS:-80}"
FS_TYPES="${FS_TYPES:-xfs ext4}"

mkdir -p "$TEST_PATH"

write_sysfs() {
    local value="$1"
    local path="$2"

    if [[ -f "$path" ]]; then
        echo "$value" | sudo tee "$path" > /dev/null
    fi
}

setup_scache() {
    write_sysfs "$STAT_DISK_NUM" /sys/kernel/stats/stats_allowed_dev_name
    write_sysfs 0 /sys/kernel/stats/stats
    write_sysfs "$BG_DISK_NUM" /sys/kernel/stats/bg_allowed_dev_name

    write_sysfs 0 /sys/fs/dsa_emu/dsa_emu_thread_numa
    write_sysfs 0 /sys/fs/dsa_emu/enable_bdp
    write_sysfs 0 /sys/fs/dsa_emu/force_node
    write_sysfs 0 /sys/fs/dsa_emu/force_node_nid
    write_sysfs 0 /sys/fs/dsa_emu/prefetch
    write_sysfs 0 /sys/fs/dsa_emu/no_zero_alloc
    write_sysfs 0 /sys/fs/dsa_emu/num_threads
    write_sysfs 1 /proc/sys/kernel/numa_balancing

    write_sysfs "$SCACHE_NR_REGIONS" /sys/fs/sc_memory/nr_regions
    write_sysfs 1 /sys/fs/sc_memory/enabled
    write_sysfs 1 /sys/kernel/stats/thread_init
}

teardown_scache() {
    write_sysfs 0 /sys/fs/sc_memory/enabled
    write_sysfs 0 /sys/kernel/stats/stats
    write_sysfs "$BG_DISK_NUM" /sys/kernel/stats/bg_allowed_dev_name
}

trap teardown_scache EXIT

prepare_mount() {
    local fs_type="$1"

    sudo umount "$DEVICE" || true
    if [[ "$fs_type" == "xfs" ]]; then
        sudo mkfs.xfs -f "$DEVICE"
    else
        sudo mkfs.ext4 -F "$DEVICE"
    fi
    sudo mount "$DEVICE" "$MOUNT_POINT"
}

prepare_testdir() {
    local test_dir="$1"

    sudo rm -rf "$MOUNT_POINT/testdir" "$MOUNT_POINT/testdir_copy" "$MOUNT_POINT/testdir.tar"
    sudo cp -r "$test_dir" "$MOUNT_POINT/testdir"
}

run_case() {
    local fs_type="$1"
    local source_label="$2"
    local test_dir="$3"
    local operation="$4"
    local drop_cache_mode="$5"
    local tested="${source_label}_${operation}_${fs_type}"
    local -a command
    local start=""
    local end=""
    local elapsed=""

    prepare_mount "$fs_type"
    prepare_testdir "$test_dir"

    echo "start_${tested}_scache"

    setup_scache
    sync
    if [[ "$drop_cache_mode" == "commented" ]]; then
        # echo 3 | sudo tee /proc/sys/vm/drop_caches
        :
    else
        echo 3 | sudo tee /proc/sys/vm/drop_caches
    fi

    start=$(date +%s.%N)
    if [[ "$operation" == "cp" ]]; then
        command=(taskset -c "$CPU_AFFINITY" sudo cp --reflink=never -r "$MOUNT_POINT/testdir" "$MOUNT_POINT/testdir_copy")
    else
        command=(taskset -c "$CPU_AFFINITY" sudo tar -c -b 512 -f "$MOUNT_POINT/testdir.tar" "$MOUNT_POINT/testdir")
    fi

    if [[ "$use_perf" -eq 1 ]]; then
        command=(sudo "$LINUX_DIR/tools/perf/perf" record --strict-freq --kcore -a -g -F2000 -o "$TEST_PATH/$tested.perf.data.scache" -- "${command[@]}")
    fi
    "${command[@]}"
    end=$(date +%s.%N)

    elapsed=$(echo "$end - $start" | bc)

    sudo cat /sys/kernel/stats/stats | tee "$TEST_PATH/stat_${tested}.scache.log"
    echo "${operation} time is : ${elapsed}s" | tee "$TEST_PATH/result_${tested}.scache.log"

    teardown_scache

    echo "end_${tested}_scache"
}

for fs_type in $FS_TYPES; do
    run_case "$fs_type" "linux" "$LINUX_DIR" "cp" "commented"
    run_case "$fs_type" "linux" "$LINUX_DIR" "tar" "commented"
    run_case "$fs_type" "generate_dir" "$SCRIPT_DIR/generate_dir" "cp" "keep"
    run_case "$fs_type" "generate_dir" "$SCRIPT_DIR/generate_dir" "tar" "keep"
done
