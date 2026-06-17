#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--postprocess-only)
			postprocess_only=1
			shift
			;;
		--help|-h)
			cat <<'EOF'
Usage: scripts/run_kafka.sh [--postprocess-only]

Runs the Kafka producer benchmark (determined coloc4 config: 120 producers,
8 I/O threads, 4 BG workers, node-0 broker+DSA, 4KB records, ext4+xfs,
orig+async by default). Kafka defaults to repos/kafka_2.13-4.0.0 in this tree.
EOF
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

postprocess_only="${postprocess_only:-0}"
preflight_repos

require_file "$KAFKA_HOME/bin/kafka-server-start.sh"
require_file "$KAFKA_HOME/bin/kafka-producer-perf-test.sh"

ts="$(timestamp_utc)"
subdir="ae_kafka_$ts"

cd "$FIO_TEST_DIR"
export BENCH_DIR="$FIO_TEST_DIR"
export LINUX_DIR
export RUN_USER="${RUN_USER:-$USER}"
export KAFKA_CONFIG="$FIO_TEST_DIR/kafka_script/kafka_config"

if [[ "$postprocess_only" == "1" ]]; then
	log "postprocessing Kafka logs/latest"
	(
		cd "$FIO_TEST_DIR/kafka_script"
		log_folder="logs/latest"
		if [[ -L "$log_folder" ]]; then
			latest_target="$(readlink "$log_folder")"
			latest_base="$(basename "$latest_target")"
			if [[ -d "logs/$latest_base" ]]; then
				log_folder="logs/$latest_base"
			fi
		fi
		KAFKA_CONFIG="$KAFKA_CONFIG" bash ./process_2.sh "$log_folder" | tee "$log_folder/summary.md"
	)
	log "summary table: $FIO_TEST_DIR/kafka_script/logs/latest/summary.md or the local timestamped logs directory"
	exit 0
fi

confirm_disposable_device
require_passwordless_sudo
preflight_kernel_surfaces
preflight_device
export_device_majmin
run_envsetup

log "running Kafka producer benchmark subdir=$subdir"
log "KAFKA_HOME=$KAFKA_HOME"

bash ./kafka_script/run_kafka.sh "$subdir"

(
	cd "$FIO_TEST_DIR/kafka_script"
	KAFKA_CONFIG="$KAFKA_CONFIG" bash ./process_2.sh "logs/$subdir" | tee "logs/$subdir/summary.md"
)

mkdir -p "$AE_RESULTS_DIR/kafka"
ln -sfn "$FIO_TEST_DIR/kafka_script/logs/$subdir" "$AE_RESULTS_DIR/kafka/latest"
log "Kafka complete: $FIO_TEST_DIR/kafka_script/logs/$subdir"
