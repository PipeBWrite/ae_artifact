#!/usr/bin/env bash

set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ae_common.sh"
set +e +o pipefail

while [[ $# -gt 0 ]]; do
	case "$1" in
		--help|-h)
			cat <<'EOF'
Usage: scripts/run_all.sh

Runs the full benchmark matrix from this checkout:
  orig+async: RocksDB/YCSB, Kafka, command tools, FIO, Log4j
  scache:     RocksDB/YCSB, command tools, FIO, Log4j, Kafka

Most stages format and mount the configured test device, so it must be disposable.
Each stage logs to results/full_ae_<timestamp>/ and the suite continues after
individual stage failures so partial results still get summarized.
EOF
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

preflight_device
ts="$(timestamp_utc)"
OUT="$AE_RESULTS_DIR/full_ae_$ts"
mkdir -p "$OUT"
SUM="$OUT/FULL_AE.md"
MANIFEST="$OUT/manifest.env"
: > "$MANIFEST"

suite_log() {
	printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$SUM"
}

latest_dir() {
	local base="$1" pattern="$2"
	find "$base" -maxdepth 1 -type d -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
		| sort -nr | awk 'NR==1 { $1=""; sub(/^ /, ""); print }'
}

record_path() {
	local key="$1" path="$2"
	[[ -n "$path" ]] || return 0
	printf '%s=%q\n' "$key" "$path" >> "$MANIFEST"
}

stage() {
	local label="$1"; shift
	suite_log ">>> START $label"
	local t0=$SECONDS rc=0
	"$@" > "$OUT/${label}.log" 2>&1
	rc=$?
	sync || true
	suite_log "<<< END   $label rc=$rc ($((SECONDS - t0))s)"
	printf '%s_rc=%s\n' "$label" "$rc" >> "$MANIFEST"
	return 0
}

{
	printf '# Full benchmark run %s\n\n' "$ts"
	printf '| Stage | rc | seconds/log |\n'
	printf '|---|---:|---|\n'
} > "$SUM"

suite_log "output root: $OUT"

(
	sudo dmesg -WT 2>/dev/null \
		| grep --line-buffered -iE 'bad page|BUG:|WARNING|Oops|hung task|blocked for more than|refcount|use-after-free|general protection|corrupt|oom-kill|dsa_emu|Threads not inited' \
		>> "$OUT/dmesg_danger.log"
) &
dmesg_pid=$!
trap 'kill "$dmesg_pid" 2>/dev/null || true' EXIT

stage check_env "$AE_SCRIPT_DIR/check_env.sh"

stage ycsb "$AE_SCRIPT_DIR/run_rocksdb_ycsb.sh"
record_path ycsb_root "$(latest_dir "$AE_RESULTS_DIR" 'rocksdb_ycsb_*')"

stage kafka "$AE_SCRIPT_DIR/run_kafka.sh"
record_path kafka_root "$(latest_dir "$FIO_TEST_DIR/kafka_script/logs" 'ae_kafka_*')"

stage command "$AE_SCRIPT_DIR/run_command_tools.sh"
record_path command_root "$(latest_dir "$AE_RESULTS_DIR" 'command_tools_*')"

stage fio "$AE_SCRIPT_DIR/run_fio_synthetic.sh"
record_path fio_root "$(latest_dir "$FIO_TEST_DIR/results" 'ae_fio_synthetic_*')"

stage fio_ablation "$AE_SCRIPT_DIR/run_fio_ablation.sh" --run
record_path fio_ablation_dir "$FIO_TEST_DIR/ablation"

stage log4j "$AE_SCRIPT_DIR/run_log4j_throughput.sh"
record_path log4j_root "$(latest_dir "$AE_RESULTS_DIR" 'log4j_throughput_*')"

stage scache "$AE_SCRIPT_DIR/run_scache_suite.sh"
record_path scache_suite_root "$(latest_dir "$AE_RESULTS_DIR" 'scache_suite_*')"
record_path scache_fio_root "$(latest_dir "$FIO_TEST_DIR/results" 'ae_fio_synthetic_*')"
record_path scache_kafka_root "$(latest_dir "$FIO_TEST_DIR/kafka_script/logs" 'ae_kafka_*')"

stage dat python3 "$AE_SCRIPT_DIR/export_gnuplot_dat.py" --manifest "$MANIFEST" --output-dir "$OUT/dat"
record_path dat_dir "$OUT/dat"

FIGURE_SCRIPT_SRC="${AE_FIGURES_SCRIPT_DIR:-$AE_ROOT/output/scripts}"
stage figures python3 "$AE_SCRIPT_DIR/render_figures.py" \
	--dat-dir "$OUT/dat" \
	--output-dir "$AE_ROOT/output" \
	--source-scripts "$FIGURE_SCRIPT_SRC"
record_path output_dir "$AE_ROOT/output"
record_path output_raw_data_dir "$AE_ROOT/output/raw_data"
record_path output_figures_dir "$AE_ROOT/output/figures"

suite_log "== FULL BENCHMARK COMPLETE $(date -u) =="
printf 'results in %s\n' "$OUT"
