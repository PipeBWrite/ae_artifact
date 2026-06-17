#!/bin/bash


# --- Setup ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# source "$SCRIPT_DIR"/../utils.sh
: "${KAFKA_CONFIG:?KAFKA_CONFIG must be set by scripts/run_kafka.sh}"
source "$KAFKA_CONFIG"


function extract_bw {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo "N/A"
    return
  fi
  for f in "$dir"/kafka_*.log; do
    [[ -f "$f" ]] && tail -n 1 "$f"
  done | grep -oP '[0-9.]+ MB/sec' | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}'
}

function extract_latency {
  # $1 = directory, $2 = pattern to match (e.g. "avg latency", "99th", "99.9th")
  local dir="$1"
  local pattern="$2"
  if [[ ! -d "$dir" ]]; then
    echo "N/A"
    return
  fi
  for f in "$dir"/kafka_*.log; do
    [[ -f "$f" ]] && tail -n 1 "$f"
  done | grep -oP "[0-9.]+ ms ${pattern}" | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "N/A"}'
}

function generate_table {
  pushd "$SCRIPT_DIR" >/dev/null || exit 1
  local log_folder="logs/latest"
  if [[ -n "$1" ]]; then
    log_folder="$1"
  fi

  async_inode_num=""
  scache_inode_num=""
  for i in $kafka_inode_nums; do
    if [[ "$i" == "scache" ]]; then
      scache_inode_num=$i
    elif [[ "$i" != "0" && -z "$async_inode_num" ]]; then
      async_inode_num=$i
    fi
  done

  # Check if we found a valid async inode number
  if [[ -z "$async_inode_num" ]]; then
    echo "Error: Could not determine the inode number for async runs." >&2
    async_inode_num="dummy"
  fi

  local -a pmem_fs_arr=()
  local -a detected_fs_arr=()
  local -a table_fs_arr=("")
  local show_fs_col=0
  if [[ -n "${pmem_fs_list:-}" ]]; then
    read -r -a pmem_fs_arr <<< "$pmem_fs_list"
    if (( ${#pmem_fs_arr[@]} > 1 )); then
      table_fs_arr=("${pmem_fs_arr[@]}")
      show_fs_col=1
    fi
  fi

  # Fallback for post-processing runs where the selected config lacks pmem_fs_list:
  # detect the new layout by scanning immediate subdirectories for kafka.* result dirs.
  if (( ! show_fs_col )) && [[ -d "./${log_folder}" ]]; then
    local has_root_layout=0
    if compgen -G "./${log_folder}/kafka.*" >/dev/null; then
      has_root_layout=1
    fi

    for subdir in "./${log_folder}"/*; do
      [[ -d "$subdir" ]] || continue
      if compgen -G "$subdir/kafka.*" >/dev/null; then
        detected_fs_arr+=("${subdir##*/}")
      fi
    done

    if (( ! has_root_layout && ${#detected_fs_arr[@]} > 0 )); then
      table_fs_arr=("${detected_fs_arr[@]}")
      show_fs_col=1
    fi
  fi

  if (( show_fs_col )); then
    echo "| FS | Producers | IOThreads | Size | BW (orig -> async -> scache) | Avg Latency (orig -> async -> scache, ms) | p99 Latency (orig -> async -> scache, ms) | p99.9 Latency (orig -> async -> scache, ms) |"
    echo "|---|---|---|---|---|---|---|---|"
  else
    echo "| Producers | IOThreads | Size | BW (orig -> async -> scache) | Avg Latency (orig -> async -> scache, ms) | p99 Latency (orig -> async -> scache, ms) | p99.9 Latency (orig -> async -> scache, ms) |"
    echo "|---|---|---|---|---|---|---|"
  fi
  for size in $kafka_sizes; do
    for producer in $kafka_producers; do
      for iothread in $kafka_iothreads; do
        for fs_name in "${table_fs_arr[@]}"; do
          fs_log_folder="$log_folder"
          if (( show_fs_col )); then
            fs_log_folder="$log_folder/$fs_name"
          fi

          orig_dir="./${fs_log_folder}/kafka.0.${iothread}.${producer}.orig.${size}"
          async_dir="./${fs_log_folder}/kafka.${async_inode_num}.${iothread}.${producer}.async.${size}"
          scache_dir="./${fs_log_folder}/kafka.${scache_inode_num}.${iothread}.${producer}.scache.${size}"

          # Skip if either log file doesn't exist
          if [[ ! -d "$orig_dir" ]] && [[ ! -d "$async_dir" ]] && [[ ! -d "$scache_dir" ]]; then
            echo "Warning: Skipping producer=${producer} iothread=${iothread}, size=${size}${fs_name:+, fs=${fs_name}}, missing dirs: ${orig_dir} ${async_dir} ${scache_dir}" >&2
            continue
          fi

          orig_single_bw=$(extract_bw "$orig_dir")
          async_single_bw=$(extract_bw "$async_dir")
          scache_single_bw=$(extract_bw "$scache_dir")

          orig_avg_lat=$(extract_latency "$orig_dir" "avg latency")
          async_avg_lat=$(extract_latency "$async_dir" "avg latency")
          scache_avg_lat=$(extract_latency "$scache_dir" "avg latency")

          orig_p99_lat=$(extract_latency "$orig_dir" "99th")
          async_p99_lat=$(extract_latency "$async_dir" "99th")
          scache_p99_lat=$(extract_latency "$scache_dir" "99th")

          orig_p999_lat=$(extract_latency "$orig_dir" "99.9th")
          async_p999_lat=$(extract_latency "$async_dir" "99.9th")
          scache_p999_lat=$(extract_latency "$scache_dir" "99.9th")

          if (( show_fs_col )); then
            printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" \
              "$fs_name" \
              "$producer" \
              "$iothread" \
              "$size" \
              "$orig_single_bw -> $async_single_bw -> $scache_single_bw" \
              "$orig_avg_lat -> $async_avg_lat -> $scache_avg_lat" \
              "$orig_p99_lat -> $async_p99_lat -> $scache_p99_lat" \
              "$orig_p999_lat -> $async_p999_lat -> $scache_p999_lat"
          else
            printf "| %s | %s | %s | %s | %s | %s | %s |\n" \
              "$producer" \
              "$iothread" \
              "$size" \
              "$orig_single_bw -> $async_single_bw -> $scache_single_bw" \
              "$orig_avg_lat -> $async_avg_lat -> $scache_avg_lat" \
              "$orig_p99_lat -> $async_p99_lat -> $scache_p99_lat" \
              "$orig_p999_lat -> $async_p999_lat -> $scache_p999_lat"
          fi
        done

      done
    done
  done
  popd >/dev/null || exit 1
}


# Check if glow is installed
if ! command -v glow &>/dev/null || ! glow --version &>/dev/null; then
  echo "glow is unavailable, generating plain text table." >&2
  generate_table "$@"
else
  generate_table "$@" | glow -w 160
fi
