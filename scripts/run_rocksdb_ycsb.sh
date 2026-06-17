#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"

# RocksDB/YCSB workloads A/B/F on ext4 and XFS, BW (orig) vs PBW (async).

WORKLOADS="a b f"
THREADS=8
NUM_RUNS=3
FS_TYPES="ext4 xfs"
CPU_AFFINITY="8-32"
OPTIONS_FILE="ycsb_option_file.ini"

preflight_repos
confirm_disposable_device
require_passwordless_sudo
preflight_kernel_surfaces
preflight_device
export_device_majmin
run_envsetup

require_cmd iostat
require_cmd bc
require_file "$YCSB_CPP_DIR/ycsb"

ts="$(timestamp_utc)"
base_out="$AE_RESULTS_DIR/rocksdb_ycsb_$ts"
mkdir -p "$base_out"

log "RocksDB/YCSB output root: $base_out"
log "workloads=$WORKLOADS threads=$THREADS runs=$NUM_RUNS fs=$FS_TYPES options=$OPTIONS_FILE"

run_one_mode() {
	local label="$1"
	local script="$2"
	local output="$base_out/$label"

	log "running YCSB mode=$label"
	cd "$YCSB_CPP_DIR"
	OUTPUT_DIR="$output" \
	WORKLOADS="$WORKLOADS" \
	THREAD_COUNTS="$THREADS" \
	NUM_RUNS="$NUM_RUNS" \
	FS_TYPES="$FS_TYPES" \
	CPU_AFFINITY="$CPU_AFFINITY" \
	OPTIONS_FILE="./$OPTIONS_FILE" \
	DEV_NAME="$AE_DEVICE" \
	MOUNT_POINT="$AE_MOUNT" \
	USE_SUDO=1 \
	"./$script"
}

run_one_mode "orig" "run_workloads.sh"
run_one_mode "async" "run_workloads_async.sh"

python3 "$AE_SCRIPT_DIR/summarize_results.py" ycsb "$base_out" "$base_out/summary.md"
log "summary table: $base_out/summary.md"
log "RocksDB/YCSB complete: $base_out"
