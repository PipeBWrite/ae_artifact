#!/bin/bash

export pmem_fs="ext4"
export pmem_fs_list="${AE_FIO_FS_LIST:-ext4 xfs}"
export use_pmem="${AE_DEVICE:-/dev/nvme0n1}"
export write_patterns="write"
export total_sizes="128G"
export calc_ttl_size_per_thread=1
export runtimes="${AE_FIO_RUNTIME:-30}"
export time_based=0
export enable_smt=0
export smt_list="0"
export use_bdp=0
export taskset_start_cpu="80"
export taskset_start_cpu_nosmt="40"
export taskset_total_cpus="$(nproc)"
export taskset_calc=1
export submit_batch_size=65536
export max_order_ent=0

export direct=0
export fsync=0
export fallocate="native"
export debug_save_pqos=0
export use_perf="0"

export wq_threads="auto"
export dsa_emu_force_fg=100
export dsa_emu_lock_wait=2
export dsa_emu_bgplan=7
export fg_loop=100

export bg_use_blkname="${AE_DEVICE_MAJMIN:-259:0}"
export stats_use_blkname="${AE_DEVICE_MAJMIN:-259:0}"

export threads="${AE_FIO_THREADS:-1 40 80}"
export blk_size="${AE_FIO_BLOCKS:-64 4k 64k}"
export config_runs="${AE_FIO_RUNS:-3}"
export inode_nums="${AE_FIO_INODE_NUMS:-0 dummy}"
