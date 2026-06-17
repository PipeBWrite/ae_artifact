#!/bin/bash

source ./fio_config
if [[ -n "$FIO_EXTRA_CONFIG" ]]; then
	source "$FIO_EXTRA_CONFIG"
fi

THIS_DIR=$(pwd)

if [[ -n $1 ]]; then
	cd $1
fi

run_times=${config_runs:-1}
if ! [[ "$run_times" =~ ^[0-9]+$ ]] || (( run_times < 1 )); then
	run_times=1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
	echo "Error: jq is required for JSON parsing. Install with: sudo apt install jq" >&2
	exit 1
fi

# Extract metrics from JSON fio output
# Returns: bw_kib avg_lat_ns p99_ns p9999_ns (space separated)
function extract_metrics_from_json {
	local file=$1
	if [[ ! -f "$file" ]]; then
		echo "0 0 0 0"
		return 0
	fi

	# Determine if it's a read or write workload based on write_patterns
	local rw_type="write"
	if [[ "$write_patterns" == *"read"* && "$write_patterns" != *"write"* ]]; then
		rw_type="read"
	fi

	jq -r --arg rw "$rw_type" '
		.jobs[0][$rw] as $job |
		if $job then
			"\($job.bw // 0) \($job.lat_ns.mean // 0) \($job.clat_ns.percentile["99.000000"] // 0) \($job.clat_ns.percentile["99.990000"] // 0)"
		else
			"0 0 0 0"
		end
	' "$file" 2>/dev/null || echo "0 0 0 0"
}

function format_bw {
	local kib=$1
	if [[ -z "$kib" || "$kib" == "0" ]]; then
		echo "N/A"
		return 0
	fi
	awk -v k="$kib" 'BEGIN {
		mib = k / 1024;
		if (mib >= 1024) printf "%.2fGiB/s", mib / 1024;
		else printf "%.2fMiB/s", mib;
	}'
}

function format_lat_ns {
	local ns=$1
	if [[ -z "$ns" || "$ns" == "0" ]]; then
		echo "N/A"
		return 0
	fi
	awk -v n="$ns" 'BEGIN {
		if (n >= 1000000000) printf "%.2fs", n / 1000000000;
		else if (n >= 1000000) printf "%.2fms", n / 1000000;
		else if (n >= 1000) printf "%.2fus", n / 1000;
		else printf "%.0fns", n;
	}'
}

function format_cpu_pct {
	local pct=$1
	if [[ -z "$pct" ]]; then
		echo "N/A"
		return 0
	fi
	awk -v p="$pct" 'BEGIN {printf "%.2f%%", p}'
}

function avg_cpu_sys_pct_for_base {
	local base=$1
	local subdir=${2:-.}
	local sum=0
	local count=0
	local file
	local val

	if (( run_times > 1 )); then
		for ((rid=1; rid<=run_times; rid++)); do
			file="${subdir}/cpu.${base}.run${rid}.summary"
			if [[ ! -f "$file" ]]; then
				continue
			fi
			val=$(grep -m1 '^peak_sys_pct=' "$file" | awk -F= '{print $2}')
			if [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
				sum=$(awk -v s="$sum" -v v="$val" 'BEGIN {printf "%.6f", s + v}')
				count=$((count + 1))
			fi
		done
	else
		file="${subdir}/cpu.${base}.summary"
		if [[ -f "$file" ]]; then
			val=$(grep -m1 '^peak_sys_pct=' "$file" | awk -F= '{print $2}')
			if [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
				sum="$val"
				count=1
			fi
		fi
	fi

	if (( count > 0 )); then
		awk -v s="$sum" -v c="$count" 'BEGIN {printf "%.6f %d", s / c, c}'
	else
		echo "0 0"
	fi
}

# Aggregate metrics across multiple runs
# Returns: avg_bw avg_lat p99 p9999 count (space separated)
function avg_metrics_for_base {
	local base=$1
	local subdir=${2:-.}
	local sum_bw=0 sum_lat=0 sum_p99=0 sum_p9999=0
	local count=0
	local file metrics bw lat p99 p9999

	if (( run_times > 1 )); then
		for ((rid=1; rid<=run_times; rid++)); do
			file="${subdir}/fio_${base}.run${rid}.json"
			if [[ ! -f "$file" ]]; then
				continue
			fi
			read -r bw lat p99 p9999 <<<"$(extract_metrics_from_json "$file")"
			if [[ -n "$bw" && "$bw" != "0" ]]; then
				sum_bw=$(awk -v s="$sum_bw" -v v="$bw" 'BEGIN {printf "%.6f", s + v}')
				sum_lat=$(awk -v s="$sum_lat" -v v="$lat" 'BEGIN {printf "%.6f", s + v}')
				sum_p99=$(awk -v s="$sum_p99" -v v="$p99" 'BEGIN {printf "%.6f", s + v}')
				sum_p9999=$(awk -v s="$sum_p9999" -v v="$p9999" 'BEGIN {printf "%.6f", s + v}')
				count=$((count + 1))
			fi
		done
	else
		file="${subdir}/fio_${base}.json"
		if [[ -f "$file" ]]; then
			read -r bw lat p99 p9999 <<<"$(extract_metrics_from_json "$file")"
			if [[ -n "$bw" && "$bw" != "0" ]]; then
				sum_bw="$bw"
				sum_lat="$lat"
				sum_p99="$p99"
				sum_p9999="$p9999"
				count=1
			fi
		fi
	fi

	if (( count > 0 )); then
		awk -v sb="$sum_bw" -v sl="$sum_lat" -v sp99="$sum_p99" -v sp9999="$sum_p9999" -v c="$count" \
			'BEGIN {printf "%.6f %.6f %.6f %.6f %d", sb/c, sl/c, sp99/c, sp9999/c, c}'
	else
		echo "0 0 0 0 0"
	fi
}

function format_with_count {
	local val=$1
	local count=$2
	local formatter=$3

	if [[ -z "$count" || "$count" -eq 0 ]]; then
		echo "N/A"
		return 0
	fi

	local formatted
	formatted=$($formatter "$val")

	if (( run_times > 1 )); then
		echo "${formatted} (n=$count)"
	else
		echo "$formatted"
	fi
}

function avg_stat_count_for_base {
	local base=$1
	local subdir=${2:-.}
	local sum=0
	local count=0
	local file
	local val
	if (( run_times > 1 )); then
		for ((rid=1; rid<=run_times; rid++)); do
			file="${subdir}/stats.${base}.run${rid}"
			if [[ ! -f "$file" ]]; then
				continue
			fi
			val=$(grep -m1 "emu_wait_loop_count_count" "$file" | awk -F: '{print $2}' | sed 's/ //g')
			if [[ -n "$val" ]]; then
				sum=$(awk -v s="$sum" -v v="$val" 'BEGIN {printf "%.6f", s + v}')
				count=$((count + 1))
			fi
		done
	else
		file="${subdir}/stats.${base}"
		if [[ -f "$file" ]]; then
			val=$(grep -m1 "emu_wait_loop_count_count" "$file" | awk -F: '{print $2}' | sed 's/ //g')
			if [[ -n "$val" ]]; then
				sum="$val"
				count=1
			fi
		fi
	fi
	if (( count > 0 )); then
		awk -v s="$sum" -v c="$count" 'BEGIN {printf "%.0f %d", s / c, c}'
	else
		echo "N/A 0"
	fi
}

function format_avg_count {
	local avg_val=$1
	local count=$2
	if [[ -z "$count" || "$count" -eq 0 || "$avg_val" == "N/A" ]]; then
		echo "N/A"
		return 0
	fi
	if (( run_times > 1 )); then
		echo "${avg_val} (n=$count)"
	else
		echo "$avg_val"
	fi
}

function print_metrics_and_cpu_for_base {
	local base=$1
	local subdir=${2:-.}
	local avg_bw avg_lat avg_p99 avg_p9999 cnt
	local avg_cpu_sys cnt_cpu

	read -r avg_bw avg_lat avg_p99 avg_p9999 cnt <<<"$(avg_metrics_for_base "$base" "$subdir")"
	printf ",%s" "$(format_with_count "$avg_bw" "$cnt" format_bw)"
	printf ",%s" "$(format_with_count "$avg_lat" "$cnt" format_lat_ns)"
	printf ",%s" "$(format_with_count "$avg_p99" "$cnt" format_lat_ns)"
	printf ",%s" "$(format_with_count "$avg_p9999" "$cnt" format_lat_ns)"

	read -r avg_cpu_sys cnt_cpu <<<"$(avg_cpu_sys_pct_for_base "$base" "$subdir")"
	printf ",%s" "$(format_with_count "$avg_cpu_sys" "$cnt_cpu" format_cpu_pct)"
}

local_smt_iter="${smt_list:-$enable_smt}"
local_fs_iter="${pmem_fs_list:-$pmem_fs}"

# Print header (tab-separated for easy Excel paste)
if (( run_times > 1 )); then
	printf "FS,SMT,Threads,Block,Size,ORIG x1 BW (avg),ORIG x1 Avg Lat,ORIG x1 p99,ORIG x1 p99.99,ORIG x1 Sys CPU (peak),ASYNC x1 BW (avg),ASYNC x1 Avg Lat,ASYNC x1 p99,ASYNC x1 p99.99,ASYNC x1 Sys CPU (peak),ASYNC x1 FG Wait Loop (avg),SCACHE x1 BW (avg),SCACHE x1 Avg Lat,SCACHE x1 p99,SCACHE x1 p99.99,SCACHE x1 Sys CPU (peak),SCACHE x1 FG Wait Loop (avg)\n"
else
	printf "FS,SMT,Threads,Block,Size,ORIG x1 BW,ORIG x1 Avg Lat,ORIG x1 p99,ORIG x1 p99.99,ORIG x1 Peak Sys CPU,ASYNC x1 BW,ASYNC x1 Avg Lat,ASYNC x1 p99,ASYNC x1 p99.99,ASYNC x1 Peak Sys CPU,ASYNC x1 FG Wait Loop,SCACHE x1 BW,SCACHE x1 Avg Lat,SCACHE x1 p99,SCACHE x1 p99.99,SCACHE x1 Peak Sys CPU,SCACHE x1 FG Wait Loop\n"
fi

for smt_val in $local_smt_iter; do
	for fs_val in $local_fs_iter; do
		subdir="smt${smt_val}/${fs_val}"
		for p in $write_patterns; do
			for t in $threads; do
				for b in $blk_size; do
					for s in $total_sizes; do
						printf "%s,%s,%s,%s,%s" "$fs_val" "$smt_val" "$t" "$b" "$s"
						for r in $runtimes; do
							for d in $direct; do
								for f in $fsync; do
									for l in $fg_loop; do
										s_new="$s"

										orig_x1_base="${fs_val}.smt${smt_val}.${p}.${t}.${s_new}.${b}.${r}.${d}.${f}.${l}.orig_x1"
										async_x1_base="${fs_val}.smt${smt_val}.${p}.${t}.${s_new}.${b}.${r}.${d}.${f}.${l}.async_x1"
										scache_x1_base="${fs_val}.smt${smt_val}.${p}.${t}.${s_new}.${b}.${r}.${d}.${f}.${l}.scache_x1"

										print_metrics_and_cpu_for_base "$orig_x1_base" "$subdir"
										print_metrics_and_cpu_for_base "$async_x1_base" "$subdir"

										read -r avg_cnt cnt_count <<<"$(avg_stat_count_for_base "$async_x1_base" "$subdir")"
										printf ",%s" "$(format_avg_count "$avg_cnt" "$cnt_count")"

										print_metrics_and_cpu_for_base "$scache_x1_base" "$subdir"

										read -r avg_cnt cnt_count <<<"$(avg_stat_count_for_base "$scache_x1_base" "$subdir")"
										printf ",%s" "$(format_avg_count "$avg_cnt" "$cnt_count")"
									done
								done
							done
						done
						printf "\n"
					done
				done
			done
		done
	done
done
