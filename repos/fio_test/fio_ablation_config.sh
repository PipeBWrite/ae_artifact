#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/fio_synthetic_config.sh"

export threads="${AE_FIO_ABLATION_THREADS:-1}"
export blk_size="${AE_FIO_ABLATION_BLOCKS:-64 4k 64k}"
export runtimes="${AE_FIO_ABLATION_RUNTIME:-${AE_FIO_RUNTIME:-30}}"
export config_runs="${AE_FIO_ABLATION_RUNS:-${AE_FIO_RUNS:-3}}"
export wq_threads="${AE_FIO_ABLATION_WQ_THREADS:-same}"
export inode_nums="${AE_FIO_ABLATION_INODE_NUMS:-0 dummy}"
