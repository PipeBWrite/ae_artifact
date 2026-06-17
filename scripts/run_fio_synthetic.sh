#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"

mode="full"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--postprocess-only)
			mode="postprocess"
			shift
			;;
		--help|-h)
			cat <<'EOF'
Usage: scripts/run_fio_synthetic.sh [--postprocess-only]

Runs the FIO synthetic sequential-write matrix from the evaluation:
  filesystems: ext4, xfs
  block sizes: 64B, 4KB, 64KB
  threads: 1, 40, 80
  modes: BW/orig, PBW/async

Use --postprocess-only to regenerate tables/plot data from copied results.
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
require_cmd jq

mkdir -p "$AE_RESULTS_DIR"

if [[ "$mode" == "postprocess" ]]; then
	log "postprocess existing FIO results"
	cd "$FIO_TEST_DIR"
	python3 ./generate_fio_plots.py
	python3 ./gen_ablation.py
	python3 "$AE_SCRIPT_DIR/summarize_results.py" fio "$FIO_TEST_DIR/out" "$FIO_TEST_DIR/out/summary.md"
	python3 "$AE_SCRIPT_DIR/summarize_results.py" fio-ablation "$FIO_TEST_DIR/ablation" "$FIO_TEST_DIR/ablation/summary.md"
	log "summary tables: $FIO_TEST_DIR/out/summary.md and $FIO_TEST_DIR/ablation/summary.md"
	log "postprocess output under $FIO_TEST_DIR/process, $FIO_TEST_DIR/out, and $FIO_TEST_DIR/ablation"
	exit 0
fi

confirm_disposable_device
require_passwordless_sudo
preflight_kernel_surfaces
preflight_device
export_device_majmin
run_envsetup

tag="ae_fio_synthetic_$(timestamp_utc)"

log "running FIO synthetic tag=$tag"
log "device=$AE_DEVICE maj:min=$AE_DEVICE_MAJMIN"

cd "$FIO_TEST_DIR"
export LINUX_DIR
export FIO_EXTRA_CONFIG="$FIO_TEST_DIR/fio_synthetic_config.sh"
export NO_CHECK_GIT=1

./get_summary.sh --tag "$tag" --summary "FIO synthetic sequential write"

python3 ./generate_fio_plots.py
python3 "$AE_SCRIPT_DIR/summarize_results.py" fio "$FIO_TEST_DIR/out" "$FIO_TEST_DIR/out/summary.md"
log "summary table: $FIO_TEST_DIR/out/summary.md"
log "FIO run complete: $FIO_TEST_DIR/results/$tag"
