#!/bin/bash

set -euo pipefail

use_perf="${use_perf:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AE_ROOT="${AE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LINUX_DIR="${LINUX_DIR:-$HOME/linux}"
COMMAND_TOOLS_CONFIG="$AE_ROOT/scripts/command_tools_config.sh"
DEVICE="${DEVICE:-/dev/nvme0n1}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/pmem}"
TEST_PATH="${TEST_PATH:-$AE_ROOT/results/command_scache}"
CPU_AFFINITY="${CPU_AFFINITY:-40}"
STAT_DISK_NUM="${STAT_DISK_NUM:-259:0}"
BG_DISK_NUM="${BG_DISK_NUM:-0:0}"
SCACHE_NR_REGIONS="${SCACHE_NR_REGIONS:-80}"
FS_TYPES="${FS_TYPES:-xfs ext4}"
COMMAND_READ_AHEAD_KB="${COMMAND_READ_AHEAD_KB:-4096}"

mkdir -p "$TEST_PATH"

if [[ ! -f "$COMMAND_TOOLS_CONFIG" ]]; then
    echo "missing command-tools config helper: $COMMAND_TOOLS_CONFIG" >&2
    exit 1
fi
# shellcheck source=scripts/command_tools_config.sh
source "$COMMAND_TOOLS_CONFIG"

setup_scache() {
    command_tools_configure_scache "$STAT_DISK_NUM" "$BG_DISK_NUM" "$SCACHE_NR_REGIONS"
}

teardown_scache() {
    command_tools_write_sysfs 0 /sys/fs/sc_memory/enabled
    command_tools_write_sysfs 0 /sys/kernel/stats/stats
    command_tools_write_sysfs "$BG_DISK_NUM" /sys/kernel/stats/bg_allowed_dev_name
}

cleanup() {
    teardown_scache
    command_tools_restore_readahead
}

trap cleanup EXIT

prepare_mount() {
    local fs_type="$1"

    sudo umount "$MOUNT_POINT" > /dev/null 2>&1 || true
    sudo mkdir -p "$MOUNT_POINT"
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
    sudo cp -a "$test_dir" "$MOUNT_POINT/testdir"
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

    sync
    if [[ "$drop_cache_mode" == "commented" ]]; then
        find "$MOUNT_POINT/testdir" -maxdepth 2 -type f -print0 2>/dev/null | xargs -0 -r cat > /dev/null || true
    else
        echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    fi

    setup_scache

    start=$(date +%s.%N)
    if [[ "$operation" == "cp" ]]; then
        command=(taskset -c "$CPU_AFFINITY" sudo cp --reflink=never -a "$MOUNT_POINT/testdir" "$MOUNT_POINT/testdir_copy")
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
    printf 'case_id=%s\nfs=%s\nmode=scache\nsource=%s\noperation=%s\ncache_mode=%s\nread_ahead_kb=%s\norig_read_ahead_kb=%s\nelapsed_s=%s\n' \
        "$tested" "$fs_type" "$source_label" "$operation" "$drop_cache_mode" "$COMMAND_TOOLS_ACTIVE_READ_AHEAD_KB" "$COMMAND_TOOLS_ORIG_READ_AHEAD_KB" "$elapsed" \
        > "$TEST_PATH/metrics_${tested}.scache.env"

    teardown_scache

    echo "end_${tested}_scache"
}

command_tools_set_readahead "$DEVICE" "$COMMAND_READ_AHEAD_KB" "$TEST_PATH/read_ahead.env" "command-tools scache"

for fs_type in $FS_TYPES; do
    run_case "$fs_type" "linux" "$LINUX_DIR" "cp" "commented"
    run_case "$fs_type" "linux" "$LINUX_DIR" "tar" "commented"
    run_case "$fs_type" "generate_dir" "$SCRIPT_DIR/generate_dir" "cp" "keep"
    run_case "$fs_type" "generate_dir" "$SCRIPT_DIR/generate_dir" "tar" "keep"
done
