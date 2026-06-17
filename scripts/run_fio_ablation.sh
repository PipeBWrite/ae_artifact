#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"

mode="postprocess"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--run)
			mode="run"
			shift
			;;
		--help|-h)
			cat <<'EOF'
Usage: scripts/run_fio_ablation.sh [--run]

By default this regenerates ablation .dat/.gnuplot files from copied result
directories. With --run, it runs the FIO ablation matrix for one booted kernel
by changing /sys/fs/dsa_emu knobs between steps.

Steps:
  Baseline   orig
  Pipeline   PBW pipeline, no folio-pool alloc, no zeroing/prefetch, no batching
  +Alloc     Pipeline + folio-pool allocation
  +Zeroing   +Alloc + nozero + prefetch
  +batching  +Zeroing + request merging/batching
EOF
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

preflight_repos
require_cmd python3

cd "$FIO_TEST_DIR"

if [[ "$mode" == "postprocess" ]]; then
	log "regenerating ablation data from copied results"
	python3 ./gen_ablation.py
	python3 "$AE_SCRIPT_DIR/summarize_results.py" fio-ablation "$FIO_TEST_DIR/ablation" "$FIO_TEST_DIR/ablation/summary.md"
	log "summary table: $FIO_TEST_DIR/ablation/summary.md"
	log "ablation data is under $FIO_TEST_DIR/ablation"
	exit 0
fi

confirm_disposable_device
require_passwordless_sudo
preflight_kernel_surfaces
preflight_device
export_device_majmin

required_knobs=(
	/sys/fs/dsa_emu/disable_batching
	/sys/fs/dsa_emu/fg_alloc_threshold
	/sys/fs/dsa_emu/no_zero_alloc
	/sys/fs/dsa_emu/prefetch
	/sys/fs/dsa_emu/num_threads
)
for knob in "${required_knobs[@]}"; do
	[[ -f "$knob" ]] || die "missing ablation knob: $knob"
done

run_envsetup

log "running FIO ablation in one booted kernel"
log "device=$AE_DEVICE maj:min=$AE_DEVICE_MAJMIN"

export LINUX_DIR
export FIO_EXTRA_CONFIG="$FIO_TEST_DIR/fio_ablation_config.sh"
export NO_CHECK_GIT=1

run_step() {
	local step="$1"
	local label="$2"
	local inode_nums="$3"
	local fg_alloc_threshold="$4"
	local no_zero_alloc="$5"
	local prefetch="$6"
	local disable_batching="$7"
	local tag="ae_fio_ablation_${step}_$(timestamp_utc)"
	local stable="ae_fio_ablation_${step}"
	local stable_path="$FIO_TEST_DIR/results/$stable"

	log "running FIO ablation step=$label tag=$tag"

	export AE_FIO_ABLATION_INODE_NUMS="$inode_nums"
	export FIO_FG_ALLOC_THRESHOLD="$fg_alloc_threshold"
	export FIO_ASYNC_NO_ZERO_ALLOC="$no_zero_alloc"
	export FIO_ASYNC_PREFETCH="$prefetch"
	export FIO_DISABLE_BATCHING="$disable_batching"
	export FIO_ORIG_NO_ZERO_ALLOC=off
	export FIO_ORIG_PREFETCH=off
	export FIO_SYNC_FALLBACK_THRESHOLD=0
	export FIO_BACKOFF_THRESHOLD_NS=0

	./get_summary.sh --tag "$tag" --summary "FIO ablation $label"

	if [[ -L "$stable_path" ]]; then
		rm "$stable_path"
	elif [[ -e "$stable_path" ]]; then
		die "stable result path exists and is not a symlink: $stable_path"
	fi
	(cd "$FIO_TEST_DIR/results" && ln -s "$tag" "$stable")
}

run_step baseline "Baseline" "0" 100 off off off
run_step pipeline "Pipeline" "dummy" 0 off off on
run_step alloc "+Alloc" "dummy" 100 off off on
run_step zeroing "+Zeroing" "dummy" 100 pbw on on
run_step batching "+batching" "dummy" 100 pbw on off

python3 ./gen_ablation.py
python3 "$AE_SCRIPT_DIR/summarize_results.py" fio-ablation "$FIO_TEST_DIR/ablation" "$FIO_TEST_DIR/ablation/summary.md"
log "summary table: $FIO_TEST_DIR/ablation/summary.md"
log "FIO ablation run complete: $FIO_TEST_DIR/ablation"
