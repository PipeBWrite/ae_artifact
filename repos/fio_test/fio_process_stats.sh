#!/bin/bash

source ./fio_config
if [[ -n "$FIO_EXTRA_CONFIG" ]]; then
	source "$FIO_EXTRA_CONFIG"
fi

THIS_DIR=`pwd`
if [[ -n $1 ]]; then
	pushd $1
fi

run_times=${config_runs:-1}
if ! [[ "$run_times" =~ ^[0-9]+$ ]] || (( run_times < 1 )); then
	run_times=1
fi

function build_run_list {
	local base=$1
	if (( run_times > 1 )); then
		local list=""
		for ((rid=1; rid<=run_times; rid++)); do
			list+="${base}.run${rid},"
		done
		echo "${list%,}"
	else
		echo "$base"
	fi
}

function print_header() {
	cat <<-EOF
		#table(
		  columns: (auto, auto, auto, auto),
		  inset: 10pt,
		  align: center,
		  table.header(
		    [*Field*], [*Time*], [*Count*], [*Average*],
		  ),
	EOF
}

local_smt_iter="${smt_list:-$enable_smt}"
local_fs_iter="${pmem_fs_list:-$pmem_fs}"

for smt_val in $local_smt_iter; do
	for fs_val in $local_fs_iter; do
		subdir="./smt${smt_val}/${fs_val}"
		for p in $write_patterns; do
			for t in $threads; do
				for s in $total_sizes; do
					for b in $blk_size; do
						for r in $runtimes; do
							for d in $direct; do
								for f in $fsync; do
									for l in $fg_loop; do
										s_new="$s"
										extra_tag="[${fs_val}-SMT${smt_val}-${p}-TIME${t}-SZ${s}-BLK${b}-TIME${r}-DIRECT${d}-FSYNC${f}-FGLOOP${l}"
										if (( run_times > 1 )); then
											extra_tag="${extra_tag}-RUNS${run_times}"
										fi
										orig_x1_stat_base="${subdir}/stats.${fs_val}.smt${smt_val}.${p}.${t}.${s_new}.${b}.${r}.${d}.${f}.${l}.orig_x1"
										async_x1_stat_base="${subdir}/stats.${fs_val}.smt${smt_val}.${p}.${t}.${s_new}.${b}.${r}.${d}.${f}.${l}.async_x1"
										scache_x1_stat_base="${subdir}/stats.${fs_val}.smt${smt_val}.${p}.${t}.${s_new}.${b}.${r}.${d}.${f}.${l}.scache_x1"
										orig_x1_stat_list=$(build_run_list "$orig_x1_stat_base")
										async_x1_stat_list=$(build_run_list "$async_x1_stat_base")
										scache_x1_stat_list=$(build_run_list "$scache_x1_stat_base")
										python3 "$THIS_DIR"/fio_stats_process.py "$orig_x1_stat_list" "$async_x1_stat_list" "$scache_x1_stat_list" "$extra_tag"
									done
								done
							done
						done
					done
				done
			done
		done
	done
done
