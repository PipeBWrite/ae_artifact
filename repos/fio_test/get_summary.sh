#!/bin/bash

set -e

export CURR_USER=${USER}
export BENCH_DIR
export LINUX_DIR="${LINUX_DIR:-$HOME/linux}"
BENCH_DIR=$(pwd)

DRY_RUN=0
while [[ $# -gt 0 ]]; do
	case $1 in
	-d | --dry-run)
		DRY_RUN=1
		shift
		;;
	-t | --tag)
		TAG=$2
		shift
		shift
		;;
	-s | --summary)
		SUMMARY=$2
		shift
		shift
		;;
	*)
		echo "Unknown option: $1"
		exit 1
		;;
	esac
done

# Check if results/$TAG exists, if it is, ask to remove it
if [[ -n "$TAG" && -d "$BENCH_DIR/results/$TAG" ]]; then
	echo "Directory $BENCH_DIR/results/$TAG already exists. Remove it? [y/n]"
	read -r answer
	if [[ $answer == "y" ]]; then
		sudo rm -rf "$BENCH_DIR/results/$TAG"
	else
		echo "Please choose another tag"
		exit 1
	fi
fi

source ./fio_config
if [[ -n "$FIO_EXTRA_CONFIG" ]]; then
	source "$FIO_EXTRA_CONFIG"
fi
source ./utils.sh

# Tag current linux dir
if [[ -n "$TAG" ]]; then
	tag_dir "$LINUX_DIR" "$TAG"
	tag_dir "$BENCH_DIR" "$TAG"
fi

check_dir "$BENCH_DIR"
check_dir "$LINUX_DIR"

if [[ -n $custom_run_script ]]; then
  echo_info ">> Running custom script: $custom_run_script"
  $custom_run_script
  exit 0
fi

if [ $DRY_RUN -eq 0 ]; then
	./fio_pmem_1t.sh
fi

if [[ -f /sys/kernel/stats/stats ]]; then
	process_stats=1
else
	process_stats=0
fi

if [[ -n $debug_custom_bin ]]; then
	echo "Custom binary: $debug_custom_bin"
	echo "Skip summary"
	exit 0
fi

function gen_summary {
	echo "= $SUMMARY <$TAG>"

	echo "////////////// AUTO GENERATED SUMMARY ////////////////////"
	echo "==== INFO"
	echo ""

	name "$LINUX_DIR" "linux"
	name "$BENCH_DIR" "bench"

	pushd "$LINUX_DIR" >/dev/null

	# Check what is defind in the file, starting with BG
	echo "- BG parts:"
	echo '```'
	cat include/linux/fbg.h
	echo '```'

	popd >/dev/null

	hn=$(hostname)
	echo "- FIO Config"
	echo '```bash'
	cat ./fio_config
	if [[ -n "$FIO_EXTRA_CONFIG" ]]; then
		echo "# FIO_EXTRA_CONFIG=$FIO_EXTRA_CONFIG"
		cat "$FIO_EXTRA_CONFIG"
	fi
	cat ./config-${hn}.sh || true
	echo '```'

	echo ""
	echo "==== BW"
	echo ""

	./fio_process_tbl.sh tmp_result

	echo ""
	echo "==== Breakdown"
	echo ""

	if [[ $process_stats -eq 0 ]]; then
		echo "No process stats available"
		exit 0
	fi

	./fio_process_stats.sh tmp_result
}

gen_summary | tee "summary.typ"

if [[ -n "$TAG" ]]; then
	./fio_move_to_tag.sh "$TAG"
fi
