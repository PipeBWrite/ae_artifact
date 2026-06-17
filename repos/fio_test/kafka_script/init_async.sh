#!/bin/bash

set -x

num_threads="$1"
dsa_numa="${2:-${kafka_dsa_numa:-0}}"
dsa_poll_usecs="${dsa_poll_usecs:-}"

set_min_max() {
    dir="$1"

    # Find all inode numbers in the directory (non-recursive), numeric sort
    read -r min max < <(
        find "$dir" -maxdepth 1 -mindepth 1 -printf '%i\n' \
        | sort -n \
        | awk 'NR==1{min=$1} {max=$1} END{print min, max}'
    )

    echo "$min $max" | sudo tee /sys/fs/dsa_emu/ignored_inode
}

sleep 1

set_min_max "/mnt/pmem/kafka-logs/__cluster_metadata-0"

if [[ -e /sys/fs/dsa_emu/dsa_emu_thread_numa ]]; then
echo "$dsa_numa" | sudo tee /sys/fs/dsa_emu/dsa_emu_thread_numa
fi

echo "${KAFKA_SAME_CORE:-off}" | sudo tee /sys/fs/dsa_emu/same_core
echo "$num_threads" | sudo tee /sys/fs/dsa_emu/num_threads
if [[ -n "$dsa_poll_usecs" && -e /sys/fs/dsa_emu/poll_usecs ]]; then
echo "$dsa_poll_usecs" | sudo tee /sys/fs/dsa_emu/poll_usecs
fi
echo on | sudo tee /sys/fs/dsa_emu/prefetch
echo all | sudo tee /sys/fs/dsa_emu/no_zero_alloc
echo off | sudo tee /sys/fs/dsa_emu/force_node
if [[ -z "${KAFKA_FOLIO_ORDER:-}" ]]; then
  case "${pmem_fs:-ext4}" in
    xfs) KAFKA_FOLIO_ORDER=6 ;;
    *)   KAFKA_FOLIO_ORDER=0 ;;
  esac
fi
if [[ -e /sys/fs/dsa_emu/folio_pool_order_max ]]; then
echo "${KAFKA_FOLIO_ORDER}" | sudo tee /sys/fs/dsa_emu/folio_pool_order_max
fi
if [[ -e /sys/fs/dsa_emu/sync_fallback_threshold ]]; then
echo "${KAFKA_SYNC_FALLBACK:-0}" | sudo tee /sys/fs/dsa_emu/sync_fallback_threshold
fi

echo "$bg_use_blkname" | sudo tee /sys/kernel/stats/bg_allowed_dev_name
echo "$bg_use_blkname" | sudo tee /sys/kernel/stats/stats_allowed_dev_name

echo 0 | sudo tee /sys/kernel/stats/stats

# echo "spin" | sudo tee /sys/fs/dsa_emu/poll_mode
# echo "400" | sudo tee /sys/fs/dsa_emu/poll_spin_max

# echo hrtimeout | sudo tee /sys/fs/dsa_emu/poll_mode
# echo 5 | sudo tee /sys/fs/dsa_emu/poll_usecs
