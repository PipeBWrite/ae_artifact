#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--prepare-dataset-only)
			prepare_only=1
			shift
			;;
		--help|-h)
			cat <<'EOF'
Usage: scripts/run_command_tools.sh [--prepare-dataset-only]

Runs command-line cp/tar experiments on:
  linux source tree, warm-cache style
  generated 3GB large dataset, cold-cache style

Full benchmark runs operate on a disposable device and require confirmation.
EOF
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

prepare_only="${prepare_only:-0}"

preflight_repos
require_cmd bc
require_cmd python3
require_cmd taskset

dataset_dir="$COMMAND_TEST_DIR/generate_dir"
dataset_files=50
dataset_file_size="300M"

prepare_large_dataset() {
	log "preparing command dataset: $dataset_files files x $dataset_file_size in $dataset_dir"
	COMMAND_DATASET_DIR="$dataset_dir" \
	COMMAND_DATASET_FILES="$dataset_files" \
	COMMAND_DATASET_FILE_SIZE="$dataset_file_size" \
		bash "$COMMAND_TEST_DIR/generate.sh"
}

if [[ "$prepare_only" == "1" ]]; then
	prepare_large_dataset
	exit 0
fi

confirm_disposable_device
require_passwordless_sudo
preflight_kernel_surfaces
preflight_device
export_device_majmin
run_envsetup

prepare_large_dataset

ts="$(timestamp_utc)"
out_dir="$AE_RESULTS_DIR/command_tools_$ts"
mkdir -p "$out_dir"

cpu="40"
fs_types="ext4 xfs"
modes="orig async"
command_source_dir="${COMMAND_SOURCE_DIR:-$LINUX_DIR}"
command_source_label="${COMMAND_SOURCE_LABEL:-linux}"
command_read_ahead_kb="4096"
read_ahead_sysfs=""
orig_read_ahead_kb=""
active_read_ahead_kb=""

require_dir "$command_source_dir"

write_sysfs() {
	local value="$1"
	local path="$2"
	if [[ -e "$path" ]]; then
		local current=""
		current="$(sudo cat "$path" 2>/dev/null | head -n 1 || true)"
		if [[ "$current" == "$value" ]]; then
			return
		fi
		printf '%s\n' "$value" | sudo tee "$path" >/dev/null
	fi
}

set_command_readahead() {
	local dev_name
	dev_name="$(basename "$AE_DEVICE")"
	read_ahead_sysfs="/sys/class/block/$dev_name/queue/read_ahead_kb"
	[[ -e "$read_ahead_sysfs" ]] || die "missing read-ahead control: $read_ahead_sysfs"

	orig_read_ahead_kb="$(cat "$read_ahead_sysfs")"
	printf '%s\n' "$command_read_ahead_kb" | sudo tee "$read_ahead_sysfs" >/dev/null
	active_read_ahead_kb="$(cat "$read_ahead_sysfs")"
	log "command-tools read_ahead_kb: $orig_read_ahead_kb -> $active_read_ahead_kb ($read_ahead_sysfs)"
	printf 'path=%s\norig_read_ahead_kb=%s\nactive_read_ahead_kb=%s\n' \
		"$read_ahead_sysfs" "$orig_read_ahead_kb" "$active_read_ahead_kb" >"$out_dir/read_ahead.env"
}

restore_command_readahead() {
	if [[ -n "$read_ahead_sysfs" && -n "$orig_read_ahead_kb" && -e "$read_ahead_sysfs" ]]; then
		printf '%s\n' "$orig_read_ahead_kb" | sudo tee "$read_ahead_sysfs" >/dev/null 2>&1 || true
	fi
}

configure_mode() {
	local mode="$1"
	write_sysfs "$AE_DEVICE_MAJMIN" /sys/kernel/stats/stats_allowed_dev_name
	write_sysfs 0 /sys/kernel/stats/stats
	write_sysfs 0 /sys/fs/sc_memory/enabled
	write_sysfs -1 /sys/fs/dsa_emu/dsa_emu_thread_numa
	write_sysfs 0 /sys/fs/dsa_emu/enable_bdp
	write_sysfs 0 /sys/fs/dsa_emu/force_node
	write_sysfs 0 /sys/fs/dsa_emu/force_node_nid
	write_sysfs 0 /proc/sys/kernel/numa_balancing
	write_sysfs 2 /sys/fs/dsa_emu/fpool_lock_wait_count

	case "$mode" in
		orig)
			write_sysfs 0 /sys/kernel/stats/bg_allowed_dev_name
			write_sysfs 0 /sys/fs/dsa_emu/num_threads
			write_sysfs 0 /sys/fs/dsa_emu/prefetch
			write_sysfs 0 /sys/fs/dsa_emu/no_zero_alloc
			;;
		async)
			write_sysfs "$AE_DEVICE_MAJMIN" /sys/kernel/stats/bg_allowed_dev_name
			write_sysfs 16 /sys/fs/dsa_emu/num_threads
			write_sysfs 1 /sys/fs/dsa_emu/prefetch
			write_sysfs 40 /sys/fs/dsa_emu/fg_alloc_threshold
			write_sysfs 2 /sys/fs/dsa_emu/force_node
			write_sysfs 1 /sys/fs/dsa_emu/no_zero_alloc
			;;
		*)
			die "unknown mode: $mode"
			;;
	esac
	write_sysfs 1 /sys/kernel/stats/thread_init
}

prepare_mount() {
	local fs="$1"
	sudo umount "$AE_MOUNT" >/dev/null 2>&1 || true
	sudo mkdir -p "$AE_MOUNT"
	case "$fs" in
		ext4) sudo mkfs.ext4 -F "$AE_DEVICE" ;;
		xfs) sudo mkfs.xfs -f "$AE_DEVICE" ;;
		*) die "unknown filesystem: $fs" ;;
	esac
	sudo mount "$AE_DEVICE" "$AE_MOUNT"
}

run_case() {
	local fs="$1"
	local mode="$2"
	local source_label="$3"
	local source_path="$4"
	local op="$5"
	local cache_mode="$6"
	local case_id="${fs}_${mode}_${source_label}_${op}"
	local case_dir="$out_dir/$case_id"
	local start end elapsed rc

	mkdir -p "$case_dir"
	prepare_mount "$fs"

	sudo rm -rf "$AE_MOUNT/testdir" "$AE_MOUNT/testdir_copy" "$AE_MOUNT/testdir.tar"
	sudo cp -a "$source_path" "$AE_MOUNT/testdir"
	sync

	if [[ "$cache_mode" == "cold" ]]; then
		echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	else
		find "$AE_MOUNT/testdir" -maxdepth 2 -type f -print0 2>/dev/null | xargs -0 -r cat >/dev/null || true
	fi

	if ! configure_mode "$mode"; then
		log "skipping $case_id: mode unavailable"
		return 0
	fi

	start="$(date +%s.%N)"
	set +e
	if [[ "$op" == "cp" ]]; then
		taskset -c "$cpu" sudo cp --reflink=never -a "$AE_MOUNT/testdir" "$AE_MOUNT/testdir_copy" >"$case_dir/stdout.log" 2>"$case_dir/stderr.log"
	else
		taskset -c "$cpu" sudo tar -c -b 512 -f "$AE_MOUNT/testdir.tar" "$AE_MOUNT/testdir" >"$case_dir/stdout.log" 2>"$case_dir/stderr.log"
	fi
	rc=$?
	set -e
	end="$(date +%s.%N)"
	elapsed="$(awk -v e="$end" -v s="$start" 'BEGIN { printf "%.6f", e - s }')"

	sudo cat /sys/kernel/stats/stats >"$case_dir/stats.log" 2>/dev/null || true
	printf 'case_id=%s\nfs=%s\nmode=%s\nsource=%s\noperation=%s\ncache_mode=%s\nread_ahead_kb=%s\norig_read_ahead_kb=%s\nelapsed_s=%s\nrc=%s\n' \
		"$case_id" "$fs" "$mode" "$source_label" "$op" "$cache_mode" "$active_read_ahead_kb" "$orig_read_ahead_kb" "$elapsed" "$rc" >"$case_dir/metrics.env"
	printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$fs" "$mode" "$source_label" "$op" "$cache_mode" "$elapsed" "$rc" "$case_dir" >>"$out_dir/metrics.csv"

	sudo umount "$AE_MOUNT" >/dev/null 2>&1 || true
}

set_command_readahead
trap restore_command_readahead EXIT

printf 'fs,mode,source,operation,cache_mode,elapsed_s,rc,case_dir\n' >"$out_dir/metrics.csv"

for fs in $fs_types; do
	for mode in $modes; do
		for op in cp tar; do
			run_case "$fs" "$mode" "$command_source_label" "$command_source_dir" "$op" "warm"
			run_case "$fs" "$mode" "large3g" "$dataset_dir" "$op" "cold"
		done
	done
done

python3 "$AE_SCRIPT_DIR/summarize_results.py" command "$out_dir" "$out_dir/summary.md"
log "summary table: $out_dir/summary.md"
log "command-tools complete: $out_dir"
