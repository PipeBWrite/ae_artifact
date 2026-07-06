#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=scripts/ae_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"
# shellcheck source=scripts/command_tools_config.sh
source "$AE_SCRIPT_DIR/command_tools_config.sh"

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

require_dir "$command_source_dir"

configure_mode() {
	local mode="$1"
	command_tools_configure_mode "$mode" "$AE_DEVICE_MAJMIN" || die "unknown mode: $mode"
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

	# shellcheck disable=SC2024 # sudo applies to the sysfs read; redirect writes to the user-owned result file.
	sudo cat /sys/kernel/stats/stats >"$case_dir/stats.log" 2>/dev/null || true
	printf 'case_id=%s\nfs=%s\nmode=%s\nsource=%s\noperation=%s\ncache_mode=%s\nread_ahead_kb=%s\norig_read_ahead_kb=%s\nelapsed_s=%s\nrc=%s\n' \
		"$case_id" "$fs" "$mode" "$source_label" "$op" "$cache_mode" "$COMMAND_TOOLS_ACTIVE_READ_AHEAD_KB" "$COMMAND_TOOLS_ORIG_READ_AHEAD_KB" "$elapsed" "$rc" >"$case_dir/metrics.env"
	printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$fs" "$mode" "$source_label" "$op" "$cache_mode" "$elapsed" "$rc" "$case_dir" >>"$out_dir/metrics.csv"

	sudo umount "$AE_MOUNT" >/dev/null 2>&1 || true
}

command_tools_set_readahead "$AE_DEVICE" "$command_read_ahead_kb" "$out_dir/read_ahead.env" "[ae] command-tools" || die "failed to set command-tools readahead"
trap command_tools_restore_readahead EXIT

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
