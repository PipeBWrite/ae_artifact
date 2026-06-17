#!/bin/bash

set -e

: "${KAFKA_CONFIG:?KAFKA_CONFIG must be set by scripts/run_kafka.sh}"
export EXTERNAL_CONFIG="$KAFKA_CONFIG"
export kafka_DIR="${KAFKA_HOME:-${kafka_DIR:-$(cd "$BENCH_DIR/.." && pwd)/kafka_2.13-4.0.0}}"
if [[ -n "${AE_JAVA_HOME:-}" ]]; then
  export JAVA_HOME="$AE_JAVA_HOME"
elif [[ -n "${JAVA_HOME:-}" ]]; then
  export JAVA_HOME
else
  JAVA_BIN="$(command -v java 2>/dev/null || true)"
  if [[ -n "$JAVA_BIN" ]]; then
    JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$JAVA_BIN")")")"
    export JAVA_HOME
  fi
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi
BIN_DIR="${kafka_DIR}/bin"
CONFIG_DIR="${kafka_DIR}/config"

export START_FILE="${BIN_DIR}/kafka-server-start.sh"
export TEST_FILE="${BIN_DIR}/kafka-producer-perf-test.sh"
export CONFIG_FILE="${CONFIG_DIR}/server.properties"

export START_FILE_TMP="${BIN_DIR}/kafka-server-start_tmp.sh"
export TEST_FILE_TMP="${BIN_DIR}/kafka-producer-perf-test_tmp.sh"
export CONFIG_FILE_TMP="${CONFIG_DIR}/server_tmp.properties"

source "$EXTERNAL_CONFIG"
source "${BENCH_DIR}"/utils.sh

if [[ "${KAFKA_SKIP_LEGACY_ENVSETUP:-1}" != "1" ]]; then
  sudo LINUX_DIR="${LINUX_DIR:-}" "${BENCH_DIR}"/envsetup.sh "$EXTERNAL_CONFIG"
fi

function retry_umount_pmem {
  local mount_target="/mnt/pmem"
  local retry_sleep_s=1

  while mountpoint -q "${mount_target}"; do
    if sudo umount "${mount_target}"; then
      echo_info "Unmounted ${mount_target}."
    else
      echo_error "umount ${mount_target} failed; retrying in ${retry_sleep_s}s..."
      sleep "${retry_sleep_s}"
    fi
  done
}

# On exit and ctrl-c
function cleanup {
  write_anyway 0 /sys/fs/sc_memory/enabled
  "${kafka_DIR}/bin/kafka-server-stop.sh" || true
  sleep 5
  if [[ -d "$kafka_DIR" ]]; then
    rm -f $kafka_DIR/bin/*_tmp.sh 2>/dev/null || true
    rm -f $kafka_DIR/config/*_tmp.properties 2>/dev/null || true
  fi
  sleep 5
  killall java || true
  sleep 2
  write_anyway 0 /sys/kernel/stats/bg_allowed_dev_name
  write_anyway 0 /sys/fs/dsa_emu/num_threads
  sudo rm -rf /mnt/pmem/kafka-logs || true
  retry_umount_pmem
  echo_info "Cleanup done."
}

trap cleanup EXIT
trap cleanup INT

function set_scache_variant {
  write_anyway off /sys/fs/dsa_emu/prefetch
  write_anyway off /sys/fs/dsa_emu/no_zero_alloc
  write_anyway off /sys/fs/dsa_emu/force_node
  write_anyway 80 /sys/fs/sc_memory/nr_regions
  write_anyway 1 /sys/fs/sc_memory/enabled
}

function cpu_list_for_numa {
  local node="$1"
  local limit="${2:-0}"
  local offset="${3:-0}"

  lscpu -e=CPU,NODE,ONLINE | awk \
    -v node="$node" -v limit="$limit" -v offset="$offset" '
      NR > 1 && $2 == node && $3 == "yes" {
        if (seen++ < offset) next
        if (limit > 0 && count >= limit) next
        printf "%s%s", count ? "," : "", $1
        count++
      }
      END { if (count == 0) exit 1 }
    '
}

function numa_nodes_except {
  local excluded="$1"

  lscpu -e=CPU,NODE,ONLINE | awk \
    -v excluded="$excluded" '
      NR > 1 && $3 == "yes" && $2 != excluded && !seen[$2]++ {
        printf "%s%s", count ? " " : "", $2
        count++
      }
      END { if (count == 0) exit 1 }
    '
}

function cpu_list_for_numa_set {
  local nodes="$1"

  lscpu -e=CPU,NODE,ONLINE | awk \
    -v nodes="$nodes" '
      BEGIN {
        split(nodes, arr, /[ ,]+/)
        for (i in arr) if (arr[i] != "") wanted[arr[i]] = 1
      }
      NR > 1 && $3 == "yes" && wanted[$2] {
        printf "%s%s", count ? "," : "", $1
        count++
      }
      END { if (count == 0) exit 1 }
    '
}

function resolve_kafka_cpu_layout {
  local server_threads="$1"
  local server_numa="${kafka_server_numa:-0}"
  local producer_numas="${kafka_producer_numas:-auto}"
  local offset="${kafka_server_cpu_offset:-0}"
  local server_cpus
  local producer_cpus

  if [[ "${kafka_cpu_list:-auto}" != "auto" ]]; then
    server_cpus="$kafka_cpu_list"
  else
    if ! server_cpus="$(cpu_list_for_numa "$server_numa" "$server_threads" "$offset")"; then
      server_cpus="$(cpu_list_for_numa "$server_numa" "$server_threads" 0)"
    fi
  fi

  if [[ "${kafka_producer_cpu_list:-auto}" != "auto" ]]; then
    producer_cpus="$kafka_producer_cpu_list"
  else
    if [[ "$producer_numas" == "auto" ]]; then
      producer_numas="$(numa_nodes_except "$server_numa")"
    fi
    producer_cpus="$(cpu_list_for_numa_set "$producer_numas")"
  fi

  printf '%s %s\n' "$server_cpus" "$producer_cpus"
}

function for_each_config {
  export kafka_DIR
  local fs_iter="${pmem_fs_list:-$pmem_fs}"
  
  for fs_val in $fs_iter; do
    export pmem_fs="$fs_val"
    for curr_i in $kafka_inode_nums; do
      for thread in $kafka_iothreads; do
        for producer in $kafka_producers; do
          for size in $kafka_sizes; do
            echo_info "Running kafka with fs: $pmem_fs inode: $curr_i threads: $thread and producer: $producer"
            $1 "$curr_i" "$thread" "$producer" "$size"
          done
        done
      done
    done
  done
}

## $1: inode number
## $2: io_thread count
## $3: producer count
## $4: kafka size
function kafka_single {
  _inode_num=$1
  _iothread_count=$2
  _producer_count=$3
  _size=$4

  if [[ "$_inode_num" == "dummy" ]]; then
    _typ="async"
  elif [[ "$_inode_num" == "scache" ]]; then
    _typ="scache"
  else
    _typ="orig"
  fi

  export file_suffix="$_inode_num"."$_iothread_count"."$_producer_count"."$_typ"."$_size"
  write_anyway 0 /sys/fs/sc_memory/enabled
  

  if [[ $stats_use_blkname != "" ]]; then
    write_anyway "$stats_use_blkname" /sys/kernel/stats/stats_allowed_dev_name
  else
    echo_error "ERR: stats_use_blkname is not set"
    exit 1
  fi

  if [[ "$_inode_num" != "dummy" && "$enable_smt" -eq 1 ]]; then
    _iothread_count=$((_iothread_count * 2))
  fi

  local dsa_threads
  local kafka_io_cpu_list
  local kafka_producer_cpu_list
  if [[ "${kafka_wqs:-same}" == "same" ]]; then
    dsa_threads="$_iothread_count"
  else
    dsa_threads="$kafka_wqs"
  fi
  read -r kafka_io_cpu_list kafka_producer_cpu_list < <(resolve_kafka_cpu_layout "$_iothread_count")


  # No perf
  # Generate worload
  bash "$BENCH_DIR/kafka_script/gen_kafka_workload.sh" "$_iothread_count" "$_producer_count" "$kafka_io_cpu_list" "$kafka_producer_cpu_list"

  echo_info "threads: $_iothread_count, inode_num: $_inode_num, file_suffix: $file_suffix, kafka_server_numa=${kafka_server_numa:-0}, kafka_dsa_numa=${kafka_dsa_numa:-${kafka_server_numa:-0}}, kafka_io_cpu_list: $kafka_io_cpu_list, kafka_producer_cpu_list: $kafka_producer_cpu_list, producer_num: $_producer_count, problem_size: $_size"

  bash "$BENCH_DIR/kafka_script/kafka_start.sh" ${_iothread_count} 



  if [[ $_inode_num == "dummy" ]]; then
    if [[ $bg_use_blkname != "" ]]; then
      bash $BENCH_DIR/kafka_script/init_async.sh "$dsa_threads" "${kafka_dsa_numa:-${kafka_server_numa:-0}}"
    else
      echo_error "ERR: bg_use_blkname is not set"
      exit 1
    fi
  else
    write_anyway 0 /sys/kernel/stats/bg_allowed_dev_name
    if [[ "$_inode_num" == "scache" ]]; then
      set_scache_variant
    fi
  fi

  if [[ $_inode_num != "dummy" ]]; then
    write_anyway 0 /sys/fs/dsa_emu/num_threads
  fi
  write_anyway 0 /sys/kernel/stats/stats
  echo 3 | sudo tee /proc/sys/vm/drop_caches

  local stats_log_dir="$log_dir"
  if [[ -n "${pmem_fs_list:-}" ]]; then
    read -r -a _pmem_fs_arr <<< "$pmem_fs_list"
    if (( ${#_pmem_fs_arr[@]} > 1 )); then
      stats_log_dir="$log_dir/$pmem_fs"
    fi
  fi
  mkdir -p "${stats_log_dir}"

  saved_dir="$stats_log_dir/kafka.$file_suffix"
  mkdir -p ${saved_dir}
  {
    printf 'fs=%s\n' "$pmem_fs"
    printf 'mode=%s\n' "$_typ"
    printf 'server_numa=%s\n' "${kafka_server_numa:-0}"
    printf 'dsa_numa=%s\n' "${kafka_dsa_numa:-${kafka_server_numa:-0}}"
    printf 'server_cpus=%s\n' "$kafka_io_cpu_list"
    printf 'producer_cpus=%s\n' "$kafka_producer_cpu_list"
    printf 'dsa_threads=%s\n' "$dsa_threads"
    printf 'kafka_num_records=%s\n' "${kafka_num_records:-1000000}"
	    if [[ -e /sys/fs/dsa_emu/dsa_emu_thread_numa ]]; then
	      printf 'dsa_emu_thread_numa='
	      sudo cat /sys/fs/dsa_emu/dsa_emu_thread_numa 2>/dev/null || true
	    fi
	    if [[ -e /sys/fs/dsa_emu/poll_usecs ]]; then
	      printf 'dsa_poll_usecs='
	      sudo cat /sys/fs/dsa_emu/poll_usecs 2>/dev/null || true
	    fi
	  } > "${saved_dir}/cpu_layout.env"

  for ((i=0; i<${_producer_count}; i++))
  do
  {
    $TEST_FILE_TMP \
      --topic test-topic \
      --num-records "${kafka_num_records:-1000000}" \
      --record-size $_size \
      --throughput -1 \
      --producer-props bootstrap.servers=localhost:9092 ${KAFKA_PRODUCER_EXTRA_PROPS:-} > ${saved_dir}/kafka_${i}.log
      # KAFKA_PRODUCER_EXTRA_PROPS e.g. "acks=1 batch.size=1048576 linger.ms=10 max.in.flight.requests.per.connection=10"
  } &
  done 
  wait 

  sleep 10

  cat_anyway /sys/kernel/stats/stats "$stats_log_dir"/stats.kafka."$file_suffix".log

  echo "------ Kafka stoped ------"

  "${kafka_DIR}/bin/kafka-server-stop.sh" || true
  sleep 5
  killall java || true
  sleep 2
  if [[ "$_inode_num" == "dummy" ]]; then
    sleep "${KAFKA_DRAIN_SLEEP:-20}"
    sync
  fi
  write_anyway 0 /sys/kernel/stats/bg_allowed_dev_name
  write_anyway 0 /sys/fs/dsa_emu/num_threads
  if [[ "$_inode_num" == "scache" ]]; then
    write_anyway 0 /sys/fs/sc_memory/enabled
  fi
  echo 3 | sudo tee /proc/sys/vm/drop_caches
  sudo rm -rf /mnt/pmem/kafka-logs || true
  retry_umount_pmem
}

# Allow user to provide a subdir name via an optional argument
if [[ -n "$1" ]]; then
  subdir_name="$1"
else
  subdir_name=$(date +"%Y%m%d%H%M%S")
fi
log_dir="${BENCH_DIR}/kafka_script/logs/$subdir_name"
mkdir -p "$log_dir"
ln -sfn "$log_dir" "${BENCH_DIR}/kafka_script/logs/latest"
for_each_config kafka_single
