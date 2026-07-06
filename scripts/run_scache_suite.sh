#!/usr/bin/env bash
# StreamCache full run (after the leak fix). Each benchmark enables the scache
# pool (nr_regions=80 -> 160 GiB), runs, and disables it. MemFree is sampled
# before/after each stage: with the leak fix it must return to ~baseline (no
# permanent loss). Kafka runs last. fio/kafka configs are switched to scache
# mode for this run and reverted on exit.
set -u
# shellcheck source=scripts/ae_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"
cd "$AE_ROOT" || exit

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      cat <<'EOF'
Usage: scripts/run_scache_suite.sh

Runs the StreamCache-only benchmark stages from this checkout:
  RocksDB/YCSB, command tools, FIO, Log4j, Kafka

Each stage enables StreamCache for that workload, disables it during cleanup,
and records logs under results/scache_suite_<timestamp>/.
EOF
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

preflight_device
export_device_majmin
run_envsetup

# The shared configuration enables `set -euo pipefail`; this suite tolerates per-stage
# failures (captures rc and continues), so drop -e/pipefail here.
set +e +o pipefail
OUT="$AE_RESULTS_DIR/scache_suite_$(timestamp_utc)"; mkdir -p "$OUT"
SUM="$OUT/SCACHE.md"; echo "# StreamCache full run (#$(uname -v|grep -o '[0-9]*'|head -1)) $(date -u)" > "$SUM"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$SUM"; }
memfree(){ awk '/MemFree/{printf "%.1f", $2/1048576}' /proc/meminfo; }
poolfree(){ sudo cat /sys/fs/sc_memory/pool_free_pages 2>/dev/null || echo NA; }

# dmesg danger watcher
(
  sudo dmesg -WT 2>/dev/null \
    | grep --line-buffered -iE "bad page|BUG:|refcount|use-after-free|__folio_lock|oom-kill|general protection|corrupt" \
    >> "$OUT/dmesg_danger.log"
) &
dmesg_pid=$!
trap 'kill "$dmesg_pid" 2>/dev/null || true' EXIT

stage(){ # label cmd...
  local label="$1"; shift
  local mf0; mf0=$(memfree)
  log ">>> START $label (MemFree ${mf0}G)"
  local t0=$SECONDS
  "$@" > "$OUT/${label}.log" 2>&1; local rc=$?
  sudo umount /mnt/pmem 2>/dev/null || true
  echo 0 | sudo tee /sys/fs/sc_memory/enabled >/dev/null 2>&1   # ensure pool down
  sleep 3; sync || true
  local mf1; mf1=$(memfree)
  log "<<< END   $label rc=$rc ($((SECONDS-t0))s) MemFree ${mf0}G->${mf1}G poolfree=$(poolfree)"
}

# 1. YCSB scache (A/B/F, ext4+xfs)
stage ycsb_scache env -C "$YCSB_CPP_DIR" OUTPUT_DIR="$OUT/ycsb" WORKLOADS="a b f" THREAD_COUNTS=8 \
  NUM_RUNS=3 FS_TYPES="ext4 xfs" OPTIONS_FILE=./ycsb_option_file.ini SCACHE_NR_REGIONS=80 \
  DEV_NAME="$AE_DEVICE" MOUNT_POINT="$AE_MOUNT" USE_SUDO=1 bash ./run_workloads_scache.sh

# 2. command-line tools scache (cp/tar, linux warm + generate_dir cold, ext4+xfs)
stage cmd_scache env DEVICE="$AE_DEVICE" MOUNT_POINT="$AE_MOUNT" FS_TYPES="ext4 xfs" \
  STAT_DISK_NUM="$AE_DEVICE_MAJMIN" SCACHE_NR_REGIONS=80 COMMAND_READ_AHEAD_KB=4096 \
  TEST_PATH="$OUT/command" AE_ROOT="$AE_ROOT" LINUX_DIR="$LINUX_DIR" bash "$COMMAND_TEST_DIR/scache_run.sh"

# 3. FIO scache
stage fio_scache env AE_FIO_INODE_NUMS="scache" bash "$AE_SCRIPT_DIR/run_fio_synthetic.sh"

# 4. Log4j scache (throughput benchmark, ext4+xfs)
stage log4j_scache env -C "$AE_ROOT/repos/log_bench" OUTPUT_DIR="$OUT/log4j" DEV_NAME="$AE_DEVICE" \
	MOUNT_POINT="$AE_MOUNT" FS_TYPE="${AE_LOG4J_FS_TYPES:-ext4 xfs}" NUM_RUNS=1 SCACHE_NR_REGIONS=80 \
	JMH_BENCHMARK="Log4JThroughputBenchmark.logHeavy|Log4JThroughputBenchmark.logComplex" \
	LOGGING_TYPES="%FS%" JMH_THREADS=4 JMH_FORKS=1 CPU_AFFINITY=8,12,16,20 \
	WARMUP_ITERATIONS=8 WARMUP_TIME=4s MEASUREMENT_ITERATIONS=4 MEASUREMENT_TIME=8s \
	LOG4J_DRAIN_DIRTY_PAGES=1 LOG4J_DIRTY_DRAIN_TIMEOUT_SEC=240 \
	JMH_EXTRA_ARGS="-jvmArgsAppend -Dlog4j.bench.immediateFlush=false -jvmArgsAppend -Dlog4j.bench.heavy.payload=7168 -jvmArgsAppend -Dlog4j.bench.complex.payload=4096" \
	USE_SUDO=1 bash ./run_streamcache.sh

# 5. Kafka scache LAST
stage kafka_scache env AE_KAFKA_INODE_NUMS="scache" bash "$AE_SCRIPT_DIR/run_kafka.sh"

log "== SCACHE SUITE COMPLETE $(date -u) =="
echo "results in $OUT"
