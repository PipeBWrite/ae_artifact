#!/bin/bash

source ./fio_config
source ./utils.sh

while [[ $# -gt 0 ]]; do
  echo_info "Sourcing $1"
  source "$1"
  shift
done

write_anyway 1 /sys/kernel/stats/thread_init
if [[ "$enable_smt" -eq 0 ]]; then
	write_anyway 0 /sys/fs/dsa_emu/smt_on
	echo off | sudo tee /sys/devices/system/cpu/smt/control
else
	write_anyway 1 /sys/fs/dsa_emu/smt_on
	echo on | sudo tee /sys/devices/system/cpu/smt/control
fi

if [[ $envsetup_disable_numa -eq 1 ]]; then
	numa_num=$(lscpu | grep 'NUMA node(s)' | rev | cut -d ' ' -f 1 | rev)
	numa_end=$(($numa_num - 1))

	declare -A numa_cpu=()
	set -e
	for i in $(seq 0 $numa_end); do
		numa_cpu[$i]=$(lscpu | grep -i "NUMA node$i CPU(s)" | rev | cut -d ' ' -f 1 | rev | sed 's/,/ /g')
		if [[ $i -ne 0 ]]; then
			if [[ $i -ne 4 ]]; then # for sub-NUMA cluster
				for c in ${numa_cpu[$i]}; do
					if [[ -n $c ]]; then
						echo 0 | sudo tee /sys/devices/system/cpu/cpu${c}/online > /dev/null
					fi
				done
			fi
		fi
	done
else
	offline_cpus=$(lscpu --offline --parse | grep -Eo '^[0-9]+')
	if [[ -n $offline_cpus ]]; then
    		while IFS= read -r cpu; do
        		echo 1 | sudo tee /sys/devices/system/cpu/cpu"$cpu"/online
    		done <<<"$offline_cpus"
	fi
fi


LINUX_DIR="${LINUX_DIR:-$HOME/linux}"
if [[ -x "$LINUX_DIR/tools/power/cpupower/cpupower" ]]; then
	pushd "$LINUX_DIR/tools/power/cpupower"
	sudo LD_LIBRARY_PATH=$(pwd) ./cpupower frequency-set -g performance
	popd
else
	echo "cpupower not found under LINUX_DIR=$LINUX_DIR; skipping CPU governor setup"
fi

# Setup dsa emu configs
if [[ "$wq_threads" != "same" ]]; then
	write_anyway "$wq_threads" /sys/fs/dsa_emu/num_threads
fi
write_anyway "$dsa_emu_lock_wait" /sys/fs/dsa_emu/fpool_lock_wait_count
write_anyway "$dsa_emu_force_fg" /sys/fs/dsa_emu/fg_alloc_threshold
write_anyway "$dsa_emu_bgplan" /sys/fs/dsa_emu/bgplan_default
write_anyway -1 /sys/fs/dsa_emu/dsa_emu_thread_numa
write_anyway "$enable_bdp" /sys/fs/dsa_emu/enable_bdp
write_anyway 0 /sys/fs/dsa_emu/force_node
write_anyway 0 /proc/sys/kernel/numa_balancing
write_anyway 0 /sys/fs/dsa_emu/force_node_nid
write_anyway 1 /sys/fs/dsa_emu/prefetch
write_anyway 1 /sys/fs/dsa_emu/no_zero_alloc
write_anyway 0 /sys/fs/dsa_emu/bg_prefetch
write_anyway 0 /sys/fs/dsa_emu/fg_delay
write_anyway "$submit_batch_size" /sys/fs/dsa_emu/batch_size
write_anyway "$max_order_ent" /sys/fs/dsa_emu/folio_pool_order_max
