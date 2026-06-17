#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"

status=0

check_cmd() {
	if command -v "$1" >/dev/null 2>&1; then
		printf '[ok] command %-12s %s\n' "$1" "$(command -v "$1")"
	else
		printf '[missing] command %s\n' "$1"
		status=1
	fi
}

check_path() {
	local path="${1:-}"
	if [[ -n "$path" && -e "$path" ]]; then
		printf '[ok] path %s\n' "$path"
	else
		printf '[missing] path %s\n' "${path:-<unset>}"
		status=1
	fi
}

check_optional_path() {
	local path="${1:-}"
	if [[ -n "$path" && -e "$path" ]]; then
		printf '[ok] optional path %s\n' "$path"
	else
		printf '[warn] optional path %s\n' "${path:-<unset>}"
	fi
}

log "AE_ROOT=$AE_ROOT"
log "LINUX_DIR=$LINUX_DIR"
log "FIO_TEST_DIR=$FIO_TEST_DIR"
log "YCSB_CPP_DIR=$YCSB_CPP_DIR"
log "COMMAND_TEST_DIR=$COMMAND_TEST_DIR"
log "KAFKA_HOME=$KAFKA_HOME"
log "JAVA_HOME=$JAVA_HOME"
log "JAVA_CMD=$JAVA_CMD"
log "AE_DEVICE=$AE_DEVICE"
log "AE_MOUNT=$AE_MOUNT"

for cmd in bash awk sed sort date find rg python3 jq fio taskset lsblk mount umount mkfs.ext4 mkfs.xfs iostat bc sudo make cmake pkg-config g++ mvn java gnuplot git curl tar; do
	check_cmd "$cmd"
done

check_path "$LINUX_DIR"
check_path "$FIO_TEST_DIR"
check_path "$YCSB_CPP_DIR"
check_path "$COMMAND_TEST_DIR"
check_path "$KAFKA_HOME"
check_path "$JAVA_HOME"
check_path "$JAVA_CMD"
check_path "$YCSB_CPP_DIR/HdrHistogram_c/CMakeLists.txt"
rocksdb_libdir="$(pkg-config --variable=libdir rocksdb 2>/dev/null || true)"
if [[ -z "$rocksdb_libdir" ]]; then
	fail "pkg-config could not find rocksdb"
else
	log "rocksdb pkg-config version=$(pkg-config --modversion rocksdb 2>/dev/null || echo unknown)"
	check_path "$rocksdb_libdir/librocksdb.a"
fi
check_path "$YCSB_CPP_DIR/ycsb"
check_path "$FIO_TEST_DIR/fio_pmem_1t.sh"
check_path "$FIO_TEST_DIR/kafka_script/run_kafka.sh"
check_path "$COMMAND_TEST_DIR/generate.sh"
check_optional_path "$LINUX_DIR/arch/x86/boot/bzImage"
check_path "$AE_ROOT/repos/log_bench/run_orig.sh"
check_path "$AE_ROOT/repos/log_bench/java-logger-benchmark/jmh-benchmarks/target/dependency"

check_path "$KAFKA_HOME/bin/kafka-server-start.sh"
check_path "$KAFKA_HOME/bin/kafka-producer-perf-test.sh"

if device_exists; then
	log "device major:minor $(device_majmin)"
else
	printf '[missing] block device %s\n' "$AE_DEVICE"
	status=1
fi

if sudo -n true >/dev/null 2>&1; then
	printf '[ok] passwordless sudo\n'
else
	printf '[missing] passwordless sudo\n'
	status=1
fi

if [[ -d /sys/fs/dsa_emu ]]; then
	printf '[ok] /sys/fs/dsa_emu\n'
	for knob in disable_batching fg_alloc_threshold no_zero_alloc prefetch num_threads; do
		check_path "/sys/fs/dsa_emu/$knob"
	done
else
	printf '[missing] /sys/fs/dsa_emu\n'
	status=1
fi

if [[ -f /sys/kernel/stats/stats ]]; then
	printf '[ok] /sys/kernel/stats/stats\n'
else
	printf '[missing] /sys/kernel/stats/stats\n'
	status=1
fi

if [[ -d /sys/fs/sc_memory ]]; then
	printf '[ok] /sys/fs/sc_memory\n'
else
	printf '[warn] /sys/fs/sc_memory missing; StreamCache runs will be skipped/fail unless enabled.\n'
fi

exit "$status"
