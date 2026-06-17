#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"

# Write-dominant log4j throughput workload (Log4JThroughputBenchmark): a
# lock-free per-thread File appender that surfaces the PBW write path, anchored
# to paper-shape absolute throughput. Heavy mirrors runLogLikeHell (14 msgs/op,
# 4KB each); complex mirrors runSingleComplexLog (markers/MDC/exception, 5KB).
# Use immediateFlush=false here to exercise Log4j's buffered/bulk write path.
# orig = BW, async = PBW. Keep all benchmark workers on one NUMA node and drain
# dirty/writeback state between runs; cross-node placement was the largest
# observed source of async variance.

LOG_BENCH_DIR="$AE_ROOT/repos/log_bench"
FS_TYPES="${AE_LOG4J_FS_TYPES:-ext4 xfs}"
JMH_THREADS=4
JMH_FORKS=1
CPU_AFFINITY="32,36,40,44"
WARMUP_ITERATIONS=8
WARMUP_TIME=4s
MEASUREMENT_ITERATIONS=4
MEASUREMENT_TIME=8s
JMH_EXTRA_ARGS="-jvmArgsAppend -Dlog4j.bench.immediateFlush=false -jvmArgsAppend -Dlog4j.bench.heavy.payload=7168 -jvmArgsAppend -Dlog4j.bench.complex.payload=4096"

require_dir "$LOG_BENCH_DIR"
require_file "$LOG_BENCH_DIR/run_orig.sh"
require_file "$LOG_BENCH_DIR/run_async.sh"
require_dir "$LOG_BENCH_DIR/java-logger-benchmark/jmh-benchmarks/target/dependency"
confirm_disposable_device
require_passwordless_sudo
preflight_kernel_surfaces
preflight_device
export_device_majmin
run_envsetup

ts="$(timestamp_utc)"
out_root="$AE_RESULTS_DIR/log4j_throughput_$ts"
mkdir -p "$out_root"
log "log4j throughput output root: $out_root"

run_mode() { # benchmark mode-label script
	local benchmark="$1" mode="$2" script="$3"
	local mode_out="$out_root/$benchmark/$mode"
	mkdir -p "$mode_out"
	log "running $benchmark mode=$mode fs=[$FS_TYPES]"
	(
		cd "$LOG_BENCH_DIR"
		OUTPUT_DIR="$mode_out" \
		DEV_NAME="$AE_DEVICE" \
		MOUNT_POINT="$AE_MOUNT" \
		FS_TYPE="$FS_TYPES" \
		NUM_RUNS=1 \
		CPU_AFFINITY="$CPU_AFFINITY" \
		JMH_THREADS="$JMH_THREADS" \
		JMH_FORKS="$JMH_FORKS" \
		JMH_BENCHMARK="Log4JThroughputBenchmark.$benchmark" \
		LOGGING_TYPES="%FS%" \
		WARMUP_ITERATIONS="$WARMUP_ITERATIONS" WARMUP_TIME="$WARMUP_TIME" \
		MEASUREMENT_ITERATIONS="$MEASUREMENT_ITERATIONS" MEASUREMENT_TIME="$MEASUREMENT_TIME" \
		LOG4J_DRAIN_DIRTY_PAGES=1 \
		LOG4J_DIRTY_DRAIN_TIMEOUT_SEC=240 \
		JMH_EXTRA_ARGS="$JMH_EXTRA_ARGS" \
		LOG4J_THREAD_NUMA=0 \
		USE_SUDO=1 \
		bash "./$script"
	)
}

report() { # benchmark
	local benchmark="$1"
	log "===== $benchmark per-iteration ops/s ====="
	local fs_type mode
	for fs_type in $FS_TYPES; do
		for mode in orig async; do
			log "--- fs=$fs_type mode=$mode ---"
			grep -E '^Iteration' "$out_root/$benchmark/$mode/$fs_type"/run_1_jmh.log 2>/dev/null | tee -a "$SUMMARY" || true
		done
	done
}

SUMMARY="$out_root/summary.txt"; : > "$SUMMARY"
for benchmark in logHeavy logComplex; do
	run_mode "$benchmark" orig  run_orig.sh
	run_mode "$benchmark" async run_async.sh
	report "$benchmark"
done

log "log4j throughput complete: $out_root"
