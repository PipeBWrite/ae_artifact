#!/bin/bash

set -e

source ./fio_config
if [[ -n "$FIO_EXTRA_CONFIG" ]]; then
	source "$FIO_EXTRA_CONFIG"
fi
source ./utils.sh

if [[ -n "$FIO_EXTRA_CONFIG" ]]; then
	sudo -E $(pwd)/envsetup.sh "$FIO_EXTRA_CONFIG"
else
	sudo -E $(pwd)/envsetup.sh
fi

sudo sysctl kernel.perf_event_max_sample_rate=10000
# sudo sysctl vm.dirty_background_bytes=204800000
# sudo sysctl vm.dirty_bytes=819200000

function block_to_bytes {
	local block=$1
	local num
	case "$block" in
		*[Kk]) num=${block%[Kk]}; echo $((num * 1024)) ;;
		*[Mm]) num=${block%[Mm]}; echo $((num * 1024 * 1024)) ;;
		*[Gg]) num=${block%[Gg]}; echo $((num * 1024 * 1024 * 1024)) ;;
		*) echo "$block" ;;
	esac
}

function xfs_set_folio_order_for_block {
	local block=$1
	if [[ "$pmem_fs" != "xfs" ]]; then
		return 0
	fi

	local bs_bytes
	bs_bytes=$(block_to_bytes "$block")
	if ! [[ "$bs_bytes" =~ ^[0-9]+$ ]] || (( bs_bytes <= 0 )); then
		echo_warning "xfs: unable to parse block size '$block', keep folio_pool_order_max unchanged"
		return 0
	fi

	local order=0
	local size=4096
	while (( bs_bytes > size )); do
		size=$((size * 2))
		order=$((order + 1))
	done

	echo_info "xfs: set folio_pool_order_max=$order for block=$block (${bs_bytes}B)"
	write_anyway "$order" /sys/fs/dsa_emu/folio_pool_order_max
}

function write_knobs {
	while (($# > 0)); do
		if (($# < 2)); then
			echo_error "write_knobs requires value/path pairs"
			return 1
		fi
		write_anyway "$1" "$2"
		shift 2
	done
}

function write_optional_knob {
	local var_name=$1
	local path=$2
	local value="${!var_name:-}"

	if [[ -n "$value" ]]; then
		write_anyway "$value" "$path"
	fi
}

function is_pbw_mode {
	local inode_num=$1
	[[ "$inode_num" != "0" && "$inode_num" != "scache" ]]
}

function async_prefetch_for {
	local threads=$1
	local block_bytes=$2

	if [[ -n "${FIO_ASYNC_PREFETCH:-}" ]]; then
		echo "$FIO_ASYNC_PREFETCH"
	elif (( threads >= 20 && block_bytes >= 16384 )); then
		echo 0
	else
		echo 1
	fi
}

function apply_common_knob_overrides {
	write_optional_knob FIO_DISABLE_BATCHING /sys/fs/dsa_emu/disable_batching
	write_optional_knob FIO_FG_ALLOC_THRESHOLD /sys/fs/dsa_emu/fg_alloc_threshold
	write_optional_knob FIO_SYNC_FALLBACK_THRESHOLD /sys/fs/dsa_emu/sync_fallback_threshold
	write_optional_knob FIO_BACKOFF_THRESHOLD_NS /sys/fs/dsa_emu/backoff_threshold_ns
}

function configure_variant_knobs {
	local inode_num=$1
	local threads=$2
	local block_bytes=$3
	local prefetch

	case "$inode_num" in
		dummy)
			prefetch=$(async_prefetch_for "$threads" "$block_bytes")
			write_knobs \
				"$prefetch" /sys/fs/dsa_emu/prefetch \
				"${FIO_ASYNC_NO_ZERO_ALLOC:-2}" /sys/fs/dsa_emu/no_zero_alloc \
				0 /sys/fs/dsa_emu/force_node
			typ="async_x1"
			;;
		scache)
			write_knobs \
				0 /sys/fs/dsa_emu/prefetch \
				0 /sys/fs/dsa_emu/no_zero_alloc \
				0 /sys/fs/dsa_emu/force_node \
				80 /sys/fs/sc_memory/nr_regions \
				1 /sys/fs/sc_memory/enabled
			typ="scache_x1"
			;;
		*)
			write_knobs \
				"${FIO_ORIG_PREFETCH:-0}" /sys/fs/dsa_emu/prefetch \
				"${FIO_ORIG_NO_ZERO_ALLOC:-0}" /sys/fs/dsa_emu/no_zero_alloc \
				0 /sys/fs/dsa_emu/force_node
			typ="orig_x1${FIO_ORIG_LABEL_SUFFIX:-}"
			;;
	esac
}

function configure_stats_gates {
	local inode_num=$1
	local bg_inode_min=$2
	local bg_inode_max=$3
	local stats_inode_min=$4
	local stats_inode_max=$5

	write_anyway "$bg_inode_min - $bg_inode_max" /sys/kernel/stats/bg_allowed_inode
	if [[ -n "${bg_use_blkname:-}" ]]; then
		if [[ "$inode_num" == "dummy" ]]; then
			write_anyway "$bg_use_blkname" /sys/kernel/stats/bg_allowed_dev_name
		else
			write_anyway "0:0" /sys/kernel/stats/bg_allowed_dev_name
		fi
	fi

	write_anyway 0 /sys/kernel/stats/stats
	echo 3 | sudo tee /proc/sys/vm/drop_caches
	write_anyway "$stats_inode_min - $stats_inode_max" /sys/kernel/stats/stats_allowed_inode
	if [[ -n "${stats_use_blkname:-}" ]]; then
		write_anyway "$stats_use_blkname" /sys/kernel/stats/stats_allowed_dev_name
	fi
	write_anyway 0 /sys/kernel/stats/stats
}

function remaining_wq_threads {
	local threads=$1
	local wq=$((80 - threads))

	if (( wq <= 8 )); then
		wq=8
	fi
	echo "$wq"
}

function set_worker_threads {
	local sched_idle=$1
	local threads=$2

	write_knobs \
		"$sched_idle" /sys/fs/dsa_emu/worker_sched_idle \
		"$threads" /sys/fs/dsa_emu/num_threads
}

function configure_auto_fallback {
	local threads=$1
	local block_bytes=$2
	local fallback_threshold=0
	local backoff_threshold_ns=0
	local backoff_duration_ns="${AE_FIO_BACKOFF_DURATION_NS:-1000000}"

	if (( threads >= 80 )); then
		fallback_threshold="${AE_FIO_80T_FALLBACK_THRESHOLD:-1}"
		backoff_threshold_ns="${AE_FIO_80T_BACKOFF_THRESHOLD_NS:-1000}"
		backoff_duration_ns="${AE_FIO_80T_BACKOFF_DURATION_NS:-10000000}"
		if (( block_bytes > 0 && block_bytes <= 2048 )); then
			fallback_threshold=0
		fi
	fi

	write_knobs \
		"$fallback_threshold" /sys/fs/dsa_emu/sync_fallback_threshold \
		"$backoff_threshold_ns" /sys/fs/dsa_emu/backoff_threshold_ns \
		"$backoff_duration_ns" /sys/fs/dsa_emu/backoff_duration_ns
}

function configure_worker_policy {
	local inode_num=$1
	local threads=$2
	local block_bytes=$3

	if ! is_pbw_mode "$inode_num"; then
		set_worker_threads 0 0
		return
	fi

	case "$wq_threads" in
		same)
			set_worker_threads 0 "$threads"
			;;
		remain)
			set_worker_threads 0 "$(remaining_wq_threads "$threads")"
			;;
		auto)
			if (( threads >= 80 )); then
				set_worker_threads "${AE_FIO_80T_WORKER_SCHED_IDLE:-1}" "${AE_FIO_80T_WQ_THREADS:-8}"
			else
				set_worker_threads 0 "$threads"
			fi
			configure_auto_fallback "$threads" "$block_bytes"
			;;
		*)
			set_worker_threads 0 "$wq_threads"
			;;
	esac
}

function cpu_sampler_loop {
	local out_file=$1
	local interval=${2:-0.02}
	local ts

	: > "$out_file"
	while true; do
		if ! read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat; then
			break
		fi
		if [[ -n "${EPOCHREALTIME:-}" ]]; then
			ts=$EPOCHREALTIME
		else
			ts=$(date +%s.%N)
		fi
		printf "%s %s %s %s %s %s %s %s %s %s %s\n" \
			"$ts" \
			"${user:-0}" \
			"${nice:-0}" \
			"${system:-0}" \
			"${idle:-0}" \
			"${iowait:-0}" \
			"${irq:-0}" \
			"${softirq:-0}" \
			"${steal:-0}" \
			"${guest:-0}" \
			"${guest_nice:-0}" >> "$out_file"
		sleep "$interval"
	done
}

function start_cpu_sampler {
	local out_file=$1
	local interval=${cpu_sample_interval_sec:-0.02}

	cpu_sampler_loop "$out_file" "$interval" </dev/null >/dev/null 2>&1 &
	echo "$!"
}

function stop_cpu_sampler {
	local pid=$1
	local out_file=$2
	local ts

	if [[ -n "$pid" ]]; then
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi

	if read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat; then
		if [[ -n "${EPOCHREALTIME:-}" ]]; then
			ts=$EPOCHREALTIME
		else
			ts=$(date +%s.%N)
		fi
		printf "%s %s %s %s %s %s %s %s %s %s %s\n" \
			"$ts" \
			"${user:-0}" \
			"${nice:-0}" \
			"${system:-0}" \
			"${idle:-0}" \
			"${iowait:-0}" \
			"${irq:-0}" \
			"${softirq:-0}" \
			"${steal:-0}" \
			"${guest:-0}" \
			"${guest_nice:-0}" >> "$out_file"
	fi
}

function summarize_cpu_usage {
	local sample_file=$1
	local summary_file=$2

	if [[ ! -s "$sample_file" ]]; then
		cat <<'EOF' > "$summary_file"
avg_user_pct=N/A
avg_sys_pct=N/A
avg_total_pct=N/A
peak_sys_pct=N/A
peak_total_pct=N/A
samples=0
intervals=0
elapsed_sec=0
EOF
		return 0
	fi

	awk '
		NR == 1 {
			start_ts = $1
			last_ts = $1
			prev_user = $2 + $3
			prev_sys = $4 + $7 + $8
			prev_idle = $5 + $6
			prev_total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
			samples = 1
			next
		}
		{
			samples++
			last_ts = $1
			user = $2 + $3
			sys = $4 + $7 + $8
			idle = $5 + $6
			total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9

			d_user = user - prev_user
			d_sys = sys - prev_sys
			d_idle = idle - prev_idle
			d_total = total - prev_total
			if (d_total > 0) {
				p_user = 100.0 * d_user / d_total
				p_sys = 100.0 * d_sys / d_total
				p_total = 100.0 * (d_total - d_idle) / d_total
				sum_user += p_user
				sum_sys += p_sys
				sum_total += p_total
				if (intervals == 0 || p_sys > peak_sys) {
					peak_sys = p_sys
				}
				if (intervals == 0 || p_total > peak_total) {
					peak_total = p_total
				}
				intervals++
			}

			prev_user = user
			prev_sys = sys
			prev_idle = idle
			prev_total = total
		}
		END {
			elapsed = (samples > 1 ? last_ts - start_ts : 0)
			if (intervals > 0) {
				printf "avg_user_pct=%.2f\n", sum_user / intervals
				printf "avg_sys_pct=%.2f\n", sum_sys / intervals
				printf "avg_total_pct=%.2f\n", sum_total / intervals
				printf "peak_sys_pct=%.2f\n", peak_sys
				printf "peak_total_pct=%.2f\n", peak_total
			} else {
				print "avg_user_pct=N/A"
				print "avg_sys_pct=N/A"
				print "avg_total_pct=N/A"
				print "peak_sys_pct=N/A"
				print "peak_total_pct=N/A"
			}
			printf "samples=%d\n", samples
			printf "intervals=%d\n", intervals
			printf "elapsed_sec=%.6f\n", elapsed
		}
	' "$sample_file" > "$summary_file"
}

function run_fio {
	local p=$1
	local t=$2
	local s=$3
	local r=$4
	local d=$5
	local i_min=$6
	local i_max=$7
	local f=$8
	local stats_inode_min=$9
	local stats_inode_max=${10}
	local inode_num=${11}
	local l=${12}
	local block=${13}
	local run_id=${14}
	local run_total=${15}
	local fallocate_opt=${fallocate:-0}
	local cpu_sample_file
	local cpu_summary_file
	local cpu_sampler_pid=""
	local fio_cmd_rc=0
	local block_bytes

	block_bytes=$(block_to_bytes "$block")
	if ! [[ "$block_bytes" =~ ^[0-9]+$ ]]; then
		block_bytes=0
	fi

	apply_common_knob_overrides
	xfs_set_folio_order_for_block "$block"
	configure_variant_knobs "$inode_num" "$t" "$block_bytes"
	file_suffix="$pmem_fs.smt${enable_smt}.$p.$t.$s.$block.$r.$d.$f.$l.$typ"
	if [[ -n "$run_total" && "$run_total" -gt 1 ]]; then
		file_suffix="${file_suffix}.run${run_id}"
	fi
	out_dir="tmp_result/smt${enable_smt}/${pmem_fs}"
	mkdir -p "$out_dir"
	cpu_sample_file="$out_dir/cpu_samples.${file_suffix}.log"
	cpu_summary_file="$out_dir/cpu.${file_suffix}.summary"

	configure_stats_gates "$inode_num" "$i_min" "$i_max" "$stats_inode_min" "$stats_inode_max"

	if [[ "$use_perf" == "1" ]]; then
		perf_cmd_event=""
		if [[ -n "$debug_perf_record_events" ]]; then
			perf_cmd_event="-e $debug_perf_record_events"
		fi
		perf_cmd="${LINUX_DIR:-$HOME/linux}/tools/perf/perf record --strict-freq --kcore $perf_cmd_event -a -g -F2000 -o $out_dir/perf.data.$file_suffix --"
		# perf_cmd="${LINUX_DIR:-$HOME/linux}/tools/perf/perf c2c record --strict-freq --kcore -a -g -F10000 -o $out_dir/perf.c2c.data.$file_suffix --"
	else
		perf_cmd=""
	fi

	if [[ -n "$debug_perf_events" || -n "$debug_perf_matrics" ]]; then
		if [[ "$use_perf" == "1" ]]; then
			echo "perf record (use_perf=1) cannot be used with perf stats (debug_perf_events is set)"
		fi

		perf_stat_list=""

		if [[ -n "$debug_perf_events" ]]; then
			perf_stat_list="-e $debug_perf_events"
		fi

		if [[ -n "$debug_perf_matrics" ]]; then
			perf_stat_list="$perf_stat_list -M $debug_perf_matrics"
		fi

		perf_stat_cmd="${LINUX_DIR:-$HOME/linux}/tools/perf/perf stat -a $perf_stat_list -o $out_dir/perf.stat.$file_suffix --"
		_use_perf_stat=1
	fi

	if [[ "$taskset_calc" == "1" ]]; then
		local taskset_second_start
		local taskset_jobs
		local total_cpus

		if [[ "${enable_smt}" == "0" ]]; then
			taskset_second_start=${taskset_start_cpu_nosmt:-40}
		else
			taskset_second_start=${taskset_start_cpu:-80}
		fi
		taskset_jobs=$t
		if [[ $inode_num == "dummy" && -n "${AE_FIO_ASYNC_TASKSET_CPUS:-}" ]]; then
			taskset_jobs=$AE_FIO_ASYNC_TASKSET_CPUS
		fi
		total_cpus=${taskset_total_cpus:-$(nproc)}

		fio_taskset_cpu=""
		if [[ $inode_num == "0" || $inode_num == "scache" ]]; then
			for ((tt=0; tt < taskset_jobs; tt++)); do
				val=$((tt % total_cpus))
				if [[ $tt -eq 0 ]]; then
					fio_taskset_cpu="$val"
				else
					fio_taskset_cpu="$fio_taskset_cpu,$val"
				fi
			done
		else
			for ((tt=0; tt < taskset_jobs; tt++)); do
				if (( taskset_second_start + tt < total_cpus )); then
					val=$((taskset_second_start + tt))
				else
					val=$((taskset_second_start - 1 - (tt - (total_cpus - taskset_second_start))))
				fi
				if [[ $tt -eq 0 ]]; then
					fio_taskset_cpu="$val"
				else
					fio_taskset_cpu="$fio_taskset_cpu,$val"
				fi
			done
		fi
	fi

	# echo in green
	if [[ $calc_ttl_size_per_thread -eq 1 ]]; then
		# remove 'G'
		num_total_size=$(echo $s | sed 's/G//')
		echo "num_total_size=$num_total_size"
		s="$((num_total_size * 1024/ t))M"
		echo "s=$s"
	fi
	echo -e "\e[32m"
	echo "Running fio with parameters:"
	echo "p=$p t=$t s=$s block=$block r=$r d=$d fallocate=$fallocate_opt i_min=$i_min i_max=$i_max f=$f stats_inode_min=$stats_inode_min stats_inode_max=$stats_inode_max inode_num=$inode_num l=$l run=${run_id:-1}/${run_total:-1}"
	echo -e "\e[0m"
	configure_worker_policy "$inode_num" "$t" "$block_bytes"

	echo "fio_taskset_cpu=$fio_taskset_cpu"
	if [[ -n "${FIO_BIN:-}" ]]; then
		fio_cmd="taskset -c $fio_taskset_cpu $FIO_BIN"
	elif [[ -x "$HOME/fio/fio" ]]; then
		fio_cmd="taskset -c $fio_taskset_cpu $HOME/fio/fio"
	else
		fio_cmd="taskset -c $fio_taskset_cpu fio"
	fi

	fio_verify_cmd=""

	if [[ $i_min -ne 0 && $i_max -ne 0 && $debug_fio_verify_async -ne 0 ]]; then
		fio_verify_cmd="$fio_verify_cmd --verify=md5 --do_verify=1"
		echo "verify async"
	elif [[ $i_min -eq 0 && $i_max -eq 0 && $debug_fio_verify_orig -ne 0 ]]; then
		fio_verify_cmd="$fio_verify_cmd --verify=md5"
		echo "verify orig"
	fi

	if [[ $time_based -eq 1 ]]; then
		fio_verify_cmd="$fio_verify_cmd --time_based"
	fi
	fio_mix_cmd=""
	if [[ -n "${FIO_RWMIXREAD:-}" ]]; then
		fio_mix_cmd="--rwmixread=${FIO_RWMIXREAD}"
	fi

	if [[ "${FIO_WARMUP_CACHE:-0}" == "1" && -z "$debug_custom_bin" ]]; then
		local warmup_rw=${FIO_WARMUP_RW:-write}
		local warmup_size=${FIO_WARMUP_SIZE:-$s}
		local warmup_bs=${FIO_WARMUP_BS:-$block}
		local warmup_rc=0

		echo "Warmup page cache: rw=$warmup_rw size=$warmup_size bs=$warmup_bs sync=${FIO_WARMUP_SYNC:-1}"
		set -x
		set +e
		sudo $fio_cmd --name=/mnt/pmem/bench --rw="$warmup_rw" \
			--numjobs="$t" \
			--ioengine=psync \
			--bs="$warmup_bs" \
			--runtime=0 \
			--group_reporting \
			--output="$out_dir"/fio_warmup_"$file_suffix".json \
			--output-format=json \
			--size="$warmup_size" \
			--blockalign=4096 \
			--direct=0 \
			--fdatasync=0 \
			--fallocate="$fallocate_opt"
		warmup_rc=$?
		set -e
		set +x
		if [[ "$warmup_rc" -ne 0 ]]; then
			echo_error "fio warmup failed (rc=$warmup_rc)"
			return "$warmup_rc"
		fi
		if [[ "${FIO_WARMUP_SYNC:-1}" == "1" ]]; then
			sync
		fi
		if [[ "${FIO_WARMUP_DROP_CACHES_AFTER:-0}" == "1" ]]; then
			echo "Drop page cache after warmup"
			sync
			echo 3 | sudo tee /proc/sys/vm/drop_caches
		fi
		write_anyway 0 /sys/kernel/stats/stats
	fi

	echo "===== test_begin =====" | sudo tee /dev/kmsg
	if [[ "$debug_save_dmesg" == "1" ]]; then
		sudo dmesg -WT >"$out_dir/dmesg_$file_suffix.log" &
		dmesg_pid=$!
		stty sane
	fi
	if [[ "$debug_save_pqos" == "1" ]]; then
		# sudo pqos -i 1 -m all:0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60 -o pqos_"$file_suffix".log &
		sudo pqos -i 1 -m all:0,4,76 -o "$out_dir"/pqos_"$file_suffix".log &
		pqos_pid=$!
		stty sane
	fi
	if [[ "$_use_perf_stat" == "1" ]]; then
		echo 0 | sudo tee /proc/sys/kernel/nmi_watchdog >/dev/null
	fi
	if [[ "$debug_lock_stat" == "1" ]]; then
		echo 0 | sudo tee /proc/lock_stat
		echo 1 | sudo tee /proc/sys/kernel/lock_stat
	fi
	cpu_sampler_pid=$(start_cpu_sampler "$cpu_sample_file")
	echo "cpu sampler: ${cpu_sample_file} (pid=${cpu_sampler_pid})"

	if [[ -n "$debug_custom_bin" ]]; then
		# if custom_bin_init is a function
		if declare -f custom_bin_init > /dev/null; then
			custom_bin_init
		fi

		set +e
		sudo $perf_cmd \
			$perf_stat_cmd \
			"$debug_custom_bin" \
			$debug_custom_bin_args
		fio_cmd_rc=$?
		set -e
	else
		set -x
		set +e
		sudo $perf_cmd \
			$perf_stat_cmd \
			$fio_cmd --name=/mnt/pmem/bench --rw="$p" \
			--numjobs="$t" \
			--ioengine=psync \
			--bs="$block" \
			--runtime="$r" \
			--group_reporting \
			--output="$out_dir"/fio_"$file_suffix".json \
			--output-format=json \
			--size="$s" \
			--blockalign=4096 \
			--blockalign=4096 \
				--direct="$d" \
				--invalidate="${FIO_INVALIDATE:-1}" \
				--fdatasync="$f" \
				--fallocate="$fallocate_opt" \
				--write_bw_log="$out_dir"/fio_bw_"$file_suffix".log \
				--log_avg_msec="${FIO_LOG_AVG_MSEC:-100}" \
				$fio_mix_cmd \
				$fio_verify_cmd
		fio_cmd_rc=$?
		set -e
		set +x
	fi
	stop_cpu_sampler "$cpu_sampler_pid" "$cpu_sample_file"
	summarize_cpu_usage "$cpu_sample_file" "$cpu_summary_file"
	cleanup_bench_files
	if [[ "$fio_cmd_rc" -ne 0 ]]; then
		echo_error "fio command failed (rc=$fio_cmd_rc), CPU summary saved to $cpu_summary_file"
		return "$fio_cmd_rc"
	fi
	printf "===== test_end =====\n" | sudo tee /dev/kmsg >/dev/null
	if [[ "$debug_lock_stat" == "1" ]]; then
		echo 0 | sudo tee /proc/sys/kernel/lock_stat
		sudo cat /proc/lock_stat | tee "$out_dir"/lock_stat_"$file_suffix".log
		echo 0 | sudo tee /proc/lock_stat
	fi
	if [[ "$debug_save_dmesg" == "1" ]]; then
		kill $dmesg_pid
		while ps -p $dmesg_pid > /dev/null
		do
			echo "dmesg process is still running, killing it"
			kill $dmesg_pid || true
			sudo pkill dmesg || true
			stty sane
		done
	fi
	if [[ "$debug_save_pqos" == "1" ]]; then
		kill $pqos_pid
		# Check if pid is still alive
		while ps -p $pqos_pid > /dev/null
		do
			echo "pqos process is still running, killing it"
			kill $pqos_pid || true
			sudo pkill pqos || true
			stty sane
		done
	fi
	if [[ "$_use_perf_stat" == "1" ]]; then
		echo 1 | sudo tee /proc/sys/kernel/nmi_watchdog >/dev/null
	fi
	stty sane || true

	if [[ "$use_perf" == "1" ]]; then
		if command -v gflame >/dev/null 2>&1; then
			gflame "$out_dir"/perf.data."$file_suffix" || true
		else
			echo "gflame not found; leaving perf.data.$file_suffix unrendered"
		fi
	fi

	if [[ "$debug_save_pqos" == "1" ]]; then
		python3 ./process_pqos_output.py "$out_dir"/pqos_"$file_suffix".log "$out_dir"/pqos_"$file_suffix"
	fi

	if [[ -z "$debug_custom_bin" ]]; then
		# python3 ./process_fio_bw_log.py fio_bw_"$file_suffix".log_bw.1.log fio_bw_"$file_suffix".svg
		echo ""
	fi

	cat_anyway /sys/kernel/stats/stats "$out_dir"/stats."$file_suffix"

	if [[ "$inode_num" == "scache" ]]; then
		write_anyway 0 /sys/fs/sc_memory/enabled
	fi
}

for_each_config run_fio
