#!/bin/bash

function init_pmem {
	set -x
	sudo umount /mnt/pmem || true

	if [[ "$use_pmem" != "0" ]]; then
		format_disk_${pmem_fs} "$use_pmem" && sudo mount "$use_pmem" /mnt/pmem
	fi

  if [[ $# -eq 1 ]]; then
	  l_threads=$1
	  for ((index = 0; index < l_threads; index++)); do
	  	sudo touch /mnt/pmem/bench.$index.0
	  done
  fi

	set +x
	# sudo touch /mnt/pmem/bench.0.0
}

function cleanup_bench_files {
	if [[ -d /mnt/pmem ]]; then
		sudo rm -f /mnt/pmem/bench*
	fi
}

function prepare_bench_files {
	local l_threads=$1
	cleanup_bench_files
	for ((index = 0; index < l_threads; index++)); do
		sudo touch /mnt/pmem/bench.$index.0
	done
}

function calc_inode_range {
	local l_threads=$1
	local max_file_inode=1
	local min_file_inode=99999999999
	local inode
	for ((index = 0; index < l_threads; index++)); do
		inode=$(stat -c %i /mnt/pmem/bench.$index.0)
		if [ "$inode" -gt "$max_file_inode" ]; then
			max_file_inode=$inode
		fi
		if [ "$inode" -lt "$min_file_inode" ]; then
			min_file_inode=$inode
		fi
	done
	echo "$min_file_inode $max_file_inode"
}

function name {
	if [[ -n "$NO_CHECK_GIT" && $NO_CHECK_GIT -eq 1 ]]; then
		echo "NO_CHECK_GIT is set, skipping git check"
		return
	fi
	dir="$1"
	tag="$2"
	pushd "$dir" >/dev/null 2>&1 || exit

	if [ -n "$(git status --porcelain)" ]; then
		echo "DIR $dir is not clean"
		exit 1
	fi

	COMMIT_ID=$(git --no-pager log -1 --pretty=format:"%h %s")

	echo "- $tag: $COMMIT_ID"

	popd >/dev/null 2>&1 || exit
}

function tag_dir {
	dir="$1"
	tag="$2"

	skip_tag=0

	echo "Tagging $dir with $tag"

	pushd "$dir" >/dev/null 2>&1 || exit
	curr_tags=$(git tag --points-at HEAD)
	for t in $curr_tags; do
		if [[ "$t" == "$tag" ]]; then
			skip_tag=1
			break
		fi
	done

	# Find if tag exist in other commits
	if [[ $skip_tag -ne 1 ]]; then
		if git rev-parse "$tag" >/dev/null 2>&1; then
			commit_id=$(git rev-parse --short "$tag")
			echo "$dir: Tag '$tag' already exists at commit ${commit_id}, replace? [y/N]"
			read -r replace
			if [[ "$replace" != "y" ]]; then
				echo "exiting"
				exit 1
			else
				git tag -d "$tag"
			fi
		fi
	fi

	if [[ "$skip_tag" -eq 0 ]]; then
		git tag "$tag"
	fi
}

function check_dir {
	if [[ -n "$NO_CHECK_GIT" && $NO_CHECK_GIT -eq 1 ]]; then
		echo "NO_CHECK_GIT is set, skipping git check"
		return
	fi

	pushd "$1" >/dev/null 2>&1 || exit
	if [ -n "$(git status --porcelain)" ]; then
		echo "DIR $1 is not clean"
		exit 1
	fi
	popd >/dev/null 2>&1 || exit
}

function apply_smt_setting {
	if [[ "$enable_smt" -eq 0 ]]; then
		write_anyway 0 /sys/fs/dsa_emu/smt_on
		echo off | sudo tee /sys/devices/system/cpu/smt/control
	else
		write_anyway 1 /sys/fs/dsa_emu/smt_on
		echo on | sudo tee /sys/devices/system/cpu/smt/control
	fi
}

function for_each_config {
	source ./fio_config
	if [[ -n "$FIO_EXTRA_CONFIG" ]]; then
		source "$FIO_EXTRA_CONFIG"
	fi
	if [[ -z $fg_loop ]]; then
		fg_loop="$dsa_emu_force_fg"
	fi
	run_times=${config_runs:-1}
	if ! [[ "$run_times" =~ ^[0-9]+$ ]] || (( run_times < 1 )); then
		run_times=1
	fi
	local smt_iter="${smt_list:-$enable_smt}"
	local fs_iter="${pmem_fs_list:-$pmem_fs}"
	for smt_val in $smt_iter; do
		enable_smt="$smt_val"
		apply_smt_setting
		for fs_val in $fs_iter; do
			pmem_fs="$fs_val"
			for p in $write_patterns; do
				for t in $threads; do
					for s in $total_sizes; do
						for r in $runtimes; do
							for d in $direct; do
								for i in $inode_nums; do
									for inode_thread_mode in x1; do
										effective_t=$t
										for f in $fsync; do
											for ff in $fg_loop; do
												for b in $blk_size; do
													init_pmem "$effective_t"
													for ((run_id=1; run_id<=run_times; run_id++)); do
														prepare_bench_files "$effective_t"
														read -r min_file_inode max_file_inode <<<"$(calc_inode_range "$effective_t")"
														if [[ "$i" == "dummy" ]]; then
															if [[ ${pmem_fs} == "xfs" ]]; then
																new_i_min=$((min_file_inode + 1))
																new_i_max=$((max_file_inode + 1))
															else
																new_i_min=$min_file_inode
																new_i_max=$max_file_inode
															fi
														else
															new_i_min=$i
															new_i_max=$i
														fi

														$1 $p $t $s $r $d $new_i_min $new_i_max $f $min_file_inode $max_file_inode $i $ff $b $run_id $run_times $inode_thread_mode
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
			done
		done
	done
}

function write_anyway {
  echo "$1 -> $2"
	if [[ -f $2 ]]; then
		local current=""
		current="$(sudo cat "$2" 2>/dev/null | head -n 1 || true)"
		if [[ "$current" == "$1" ]]; then
			return 0
		fi
		echo "$1" | sudo tee -a "$2" > /dev/null
	else
		return 0
	fi
}

function cat_anyway {
	if [[ -f $1 ]]; then
		sudo cat "$1" >"$2"
	else
		echo -e "\033[33m$1 not found\033[0m"
		return 0
	fi
}

function format_disk_ext4 {
	# Format the disk with ext4
	sudo mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 $1
}

function format_disk_xfs {
	# Format the disk with xfs
	sudo mkfs.xfs -f $1
}

function echo_and_tee {
	echo "$1" | tee -a "$2"
}

function echo_and_tee_summary {
	echo_and_tee "$1" "summary.typ"
}

function echo_info {
  echo -e "\033[32m$1\033[0m"
}

function echo_error {
  echo -e "\033[31m$1\033[0m"
}

function echo_warning {
  echo -e "\033[33m$1\033[0m"
}
