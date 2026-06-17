#!/usr/bin/env bash
# common.sh - Shared configuration and functions for YCSB-cpp run scripts
#
# Source this file from your run script, set script-specific variables,
# then call load_common_config and init_run.

# --- Default Configuration (override before calling load_common_config) ---
YCSB_EXEC="${YCSB_EXEC:-./ycsb}"
WORKLOAD_DIR="${WORKLOAD_DIR:-./workloads}"
OPTIONS_FILE="${OPTIONS_FILE:-./ycsb_option_file.ini}"
WORKLOADS="${WORKLOADS:-a}"
NUM_RUNS="${NUM_RUNS:-10}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/pmem}"
DEV_NAME="${DEV_NAME:-/dev/nvme0n1}"
STATS_FILE="${STATS_FILE:-/sys/kernel/stats/stats}"
CPU_AFFINITY="${CPU_AFFINITY:-0-159}"
THREAD_COUNTS="${THREAD_COUNTS:-8}"
DB_NAME="${DB_NAME:-rocksdb}"                # rocksdb | leveldb | sqlite
DB_PROPERTY_FILE="${DB_PROPERTY_FILE:-}"     # default depends on DB_NAME
DB_PATH="${DB_PATH:-}"                       # default depends on DB_NAME
FS_TYPES="${FS_TYPES:-ext4 xfs}"                # ext4 | xfs - space-separated list of filesystems
YCSB_EXTRA_ARGS="${YCSB_EXTRA_ARGS:-}"       # optional, shell-split
RUN_USER="${RUN_USER:-$(id -un)}"
RUN_GROUP="${RUN_GROUP:-$(id -gn)}"
USE_SUDO="${USE_SUDO:-auto}"               # auto | 1 | 0
REPORT_SYSTEM_CPU_USAGE="${REPORT_SYSTEM_CPU_USAGE:-0}" # 1 enables per-run CPU usage capture

# --- Helper Functions ---

run_privileged() {
    if [[ "$USE_SUDO" == "1" ]]; then
        sudo -n "$@"
    else
        "$@"
    fi
}

write_sysfs() {
    local value="$1"
    local path="$2"
    if [[ -e "$path" ]]; then
        if [[ -w "$path" ]]; then
            printf "%s\n" "$value" >"$path" 2>/dev/null || true
        elif [[ "$USE_SUDO" == "1" ]]; then
            printf "%s\n" "$value" | run_privileged tee "$path" >/dev/null 2>/dev/null || true
        fi
    fi
}

format_disk_ext4() {
    run_privileged mkfs.ext4 -F "$1"
}

format_disk_xfs() {
    run_privileged mkfs.xfs -f "$1"
}

format_and_mount() {
    "format_disk_${FS_TYPE}" "$DEV_NAME"
    run_privileged mount "$DEV_NAME" "$MOUNT_POINT"
    run_privileged chown -R "$RUN_USER:$RUN_GROUP" "$MOUNT_POINT"
}

build_ycsb_command() {
    local phase="$1"      # load|run
    local workload="$2"   # workload suffix, e.g. a/b/c
    local -n out_cmd="$3"

    out_cmd=(
        taskset -c "$CPU_AFFINITY"
        "$YCSB_EXEC"
        "-$phase"
        -db "$DB_NAME"
        -s
        -P "$WORKLOAD_DIR/workload${workload}"
    )

    if [[ -n "$DB_PROPERTY_FILE" ]]; then
        out_cmd+=(-P "$DB_PROPERTY_FILE")
    fi
    out_cmd+=(-p "$DB_PATH_PROP_KEY=$DB_PATH")

    if [[ "$DB_NAME" == "rocksdb" ]]; then
        out_cmd+=(-p "rocksdb.optionsfile=$OPTIONS_FILE")
    fi

    if [[ -n "$YCSB_EXTRA_ARGS" ]]; then
        # Allow passing free-form extra CLI args via env var.
        # shellcheck disable=SC2206
        local extra_args=( $YCSB_EXTRA_ARGS )
        out_cmd+=("${extra_args[@]}")
    fi
}

run_ycsb_and_capture() {
    local output_file
    local run_rc
    local tee_rc
    local -a pipe_status

    output_file="$(mktemp "${TMPDIR:-/tmp}/ycsb_output.XXXXXX")" || return 1
    "$@" | tee "$output_file"
    pipe_status=("${PIPESTATUS[@]}")
    run_rc=${pipe_status[0]}
    tee_rc=${pipe_status[1]}
    YCSB_OUTPUT="$(cat "$output_file")"
    rm -f "$output_file"

    if [[ "$run_rc" -ne 0 ]]; then
        return "$run_rc"
    fi
    return "$tee_rc"
}

clean_database_path() {
    if [[ "$DB_NAME" == "sqlite" ]]; then
        local db_dir
        db_dir="$(dirname "$DB_PATH")"
        if [[ "$USE_SUDO" == "1" ]]; then
            run_privileged mkdir -p "$db_dir"
            run_privileged rm -f "$DB_PATH"
            run_privileged chown -R "$RUN_USER:$RUN_GROUP" "$db_dir"
        else
            mkdir -p "$db_dir"
            rm -f "$DB_PATH"
        fi
    else
        if [[ "$USE_SUDO" == "1" ]]; then
            run_privileged rm -rf "$DB_PATH"
        else
            rm -rf "$DB_PATH"
        fi
    fi
}

set_manifest_ignore_inode() {
    if [[ "$DB_HAS_MANIFEST" != "1" ]]; then
        return
    fi

    local manifest_file
    manifest_file="$(find "$DB_PATH" -maxdepth 1 -type f -name "MANIFEST-*" | head -n 1)"
    if [[ -n "$manifest_file" ]]; then
        local ignore_inode
        ignore_inode="$(stat -c '%i' "$manifest_file")"
        write_sysfs "$ignore_inode $ignore_inode" /sys/fs/dsa_emu/ignored_inode
    else
        echo "Warning: Could not find MANIFEST file in $DB_PATH"
    fi
}

parse_and_aggregate_kernel_stats() {
    local key_time="$1"
    local key_count="$2"
    local total_time_var="$3"
    local total_count_var="$4"

    local time
    local count
    time="$(echo "$STATS" | awk -F'[:,]' -v key="$key_time" '$0 ~ key {gsub(/ /, "", $2); print $2; exit}')"
    count="$(echo "$STATS" | awk -F'[:,]' -v key="$key_count" '$0 ~ key {gsub(/ /, "", $4); print $4; exit}')"

    [[ -z "$time" ]] && time=0
    [[ -z "$count" ]] && count=0

    eval "$total_time_var=\$(( \${$total_time_var:-0} + $time ))"
    eval "$total_count_var=\$(( \${$total_count_var:-0} + $count ))"
}

calculate_average() {
    local total="$1"
    local count="$2"
    if [[ "$count" -gt 0 ]]; then
        echo "scale=2; $total / $count" | bc
    else
        echo "0"
    fi
}

float_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

float_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

parse_ycsb_operation_metrics() {
    local ycsb_output="$1"

    awk '
        /operations; \[/ { line=$0 }
        END {
            if (line == "") {
                exit
            }

            duration_sec = 0
            if (match(line, /([0-9]+([.][0-9]+)?) sec:/)) {
                duration_sec = substr(line, RSTART, RLENGTH)
                gsub(/ sec:/, "", duration_sec)
            }

            rest = line
            while (match(rest, /\[[^][]+\]/)) {
                segment = substr(rest, RSTART + 1, RLENGTH - 2)
                rest = substr(rest, RSTART + RLENGTH)

                colon_pos = index(segment, ":")
                if (colon_pos == 0) {
                    continue
                }
                op = substr(segment, 1, colon_pos - 1)
                metrics = substr(segment, colon_pos + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", op)

                count = 0
                lat_min = 0
                lat_max = 0
                lat_avg = 0
                p99 = 0
                p999 = 0
                p9999 = 0

                n = split(metrics, parts, /[[:space:]]+/)
                for (i = 1; i <= n; i++) {
                    if (index(parts[i], "=") == 0) {
                        continue
                    }
                    split(parts[i], kv, "=")
                    key = kv[1]
                    value = kv[2]
                    if (key == "Count") count = value
                    else if (key == "Min") lat_min = value
                    else if (key == "Max") lat_max = value
                    else if (key == "Avg") lat_avg = value
                    else if (key == "99") p99 = value
                    else if (key == "99.9") p999 = value
                    else if (key == "99.99") p9999 = value
                }

                throughput = 0
                if (duration_sec > 0) {
                    throughput = count / duration_sec
                }

                printf "%s\t%.0f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\n", \
                    op, count, throughput, lat_min, lat_max, lat_avg, p99, p999, p9999
            }
        }
    ' <<< "$ycsb_output"
}

print_run_operation_table() {
    local stats_tsv="$1"
    local out_file="$2"
    local workload="$3"
    local threads="$4"
    local run_id="$5"

    {
        echo "===== Per-Run Operation Stats ====="
        echo "Workload: $workload, Threads: $threads, Run: $run_id"
        echo "Latency unit: us"
        printf "%-12s %12s %18s %12s %12s %12s %12s %12s %12s\n" \
            "Operation" "Count" "Throughput(ops/s)" "Min" "Max" "Avg" "P99" "P99.9" "P99.99"
        printf "%-12s %12s %18s %12s %12s %12s %12s %12s %12s\n" \
            "------------" "------------" "------------------" "------------" "------------" "------------" "------------" "------------" "------------"
        awk -F'\t' '
            NF >= 9 {
                printf "%-12s %12.0f %18.2f %12.2f %12.2f %12.2f %12.2f %12.2f %12.2f\n",
                    $1, $2, $3, $4, $5, $6, $7, $8, $9
            }
        ' "$stats_tsv"
        echo ""
    } > "$out_file"
}

print_operation_summary_table() {
    local stats_tsv="$1"

    echo "--- Per-Operation Throughput (Across Runs) ---"
    printf "%-12s %10s %16s %16s %16s\n" \
        "Operation" "Runs" "Thr Min(op/s)" "Thr Max(op/s)" "Thr Avg(op/s)"
    printf "%-12s %10s %16s %16s %16s\n" \
        "------------" "----------" "----------------" "----------------" "----------------"

    awk -F'\t' '
        NF >= 10 {
            op = $2
            thr = $4 + 0

            if (!(op in seen)) {
                seen[op] = 1
                min_thr[op] = thr
                max_thr[op] = thr
            }
            if (thr < min_thr[op]) min_thr[op] = thr
            if (thr > max_thr[op]) max_thr[op] = thr

            total_thr[op] += thr
            run_count[op]++
        }
        END {
            for (op in seen) {
                avg_thr = (run_count[op] > 0) ? total_thr[op] / run_count[op] : 0

                printf "%s\t%d\t%.2f\t%.2f\t%.2f\n",
                    op, run_count[op], min_thr[op], max_thr[op], avg_thr
            }
        }
    ' "$stats_tsv" | sort -k1,1 | awk -F'\t' '
        {
            printf "%-12s %10d %16.2f %16.2f %16.2f\n",
                $1, $2, $3, $4, $5
        }
    '
    echo ""

    echo "--- Per-Operation Latencies (Across Runs, us) ---"
    printf "%-12s %-12s %12s %12s %12s\n" \
        "Operation" "Metric" "Min" "Max" "Avg"
    printf "%-12s %-12s %12s %12s %12s\n" \
        "------------" "------------" "------------" "------------" "------------"

    awk -F'\t' '
        function update_stat(op, metric_idx, value,     key) {
            key = op SUBSEP metric_idx
            if (!(key in seen_metric)) {
                seen_metric[key] = 1
                min_v[key] = value
                max_v[key] = value
            }
            if (value < min_v[key]) min_v[key] = value
            if (value > max_v[key]) max_v[key] = value
            sum_v[key] += value
            cnt_v[key]++
        }
        BEGIN {
            metric_name[1] = "MinLat"
            metric_name[2] = "MaxLat"
            metric_name[3] = "AvgLat"
            metric_name[4] = "P99"
            metric_name[5] = "P99.9"
            metric_name[6] = "P99.99"
        }
        NF >= 10 {
            op = $2
            update_stat(op, 1, $5 + 0)
            update_stat(op, 2, $6 + 0)
            update_stat(op, 3, $7 + 0)
            update_stat(op, 4, $8 + 0)
            update_stat(op, 5, $9 + 0)
            update_stat(op, 6, $10 + 0)
            seen_op[op] = 1
        }
        END {
            for (op in seen_op) {
                for (m = 1; m <= 6; m++) {
                    key = op SUBSEP m
                    if (!(key in cnt_v) || cnt_v[key] == 0) {
                        continue
                    }
                    avg_v = sum_v[key] / cnt_v[key]
                    printf "%s\t%d\t%s\t%.2f\t%.2f\t%.2f\n",
                        op, m, metric_name[m], min_v[key], max_v[key], avg_v
                }
            }
        }
    ' "$stats_tsv" | sort -k1,1 -k2,2n | awk -F'\t' '
        {
            printf "%-12s %-12s %12.2f %12.2f %12.2f\n",
                $1, $3, $4, $5, $6
        }
    '
    echo ""
}

read_cpu_jiffies() {
    local total_var="$1"
    local idle_var="$2"
    local total=0
    local idle=0

    if ! read -r total idle < <(awk '
        /^cpu / {
            print ($2 + $3 + $4 + $5 + $6 + $7 + $8 + $9), ($5 + $6)
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' /proc/stat 2>/dev/null); then
        eval "$total_var=0"
        eval "$idle_var=0"
        return 1
    fi

    eval "$total_var=$total"
    eval "$idle_var=$idle"
}

calculate_cpu_usage_percent() {
    local start_total="$1"
    local start_idle="$2"
    local end_total="$3"
    local end_idle="$4"
    local delta_total=$((end_total - start_total))
    local delta_idle=$((end_idle - start_idle))

    if (( delta_total <= 0 )); then
        echo "0"
        return
    fi

    awk -v dt="$delta_total" -v di="$delta_idle" '
        BEGIN {
            usage = ((dt - di) * 100) / dt
            if (usage < 0) usage = 0
            if (usage > 100) usage = 100
            printf "%.2f", usage
        }
    '
}

print_summary_header() {
    local file="$1"
    {
        echo "===== YCSB-cpp Workload Summary ====="
        echo "Timestamp: $(date)"
        echo "======================================="
        echo ""
    } > "$file"
}

print_metric_stats() {
    local title="$1"
    local time="$2"
    local count="$3"
    local avg
    avg="$(calculate_average "$time" "$count")"

    printf "% -30s %15s\n" "--- $title ---" ""
    printf "% -30s %15d\n" "Total Time (ns)" "$time"
    printf "% -30s %15d\n" "Total Count" "$count"
    printf "% -30s %15.2f %s\n" "Avg Latency" "$avg" "ns"
    echo ""
}

stop_iostat() {
    local pid="$1"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -INT "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

# --- Load configuration (call after setting overrides) ---
load_common_config() {
    OUTPUT_DIR="${OUTPUT_DIR:-output/cpp_$(date +"%Y-%m-%d_%H-%M-%S")}"
    SUMMARY_FILE="$OUTPUT_DIR/summary.log"
    RUN_STATS_SUBDIR="${RUN_STATS_SUBDIR:-run_stats_tables}"
    RUN_STATS_DIR="${RUN_STATS_DIR:-$OUTPUT_DIR/$RUN_STATS_SUBDIR}"

    case "$USE_SUDO" in
        auto)
            if sudo -n true >/dev/null 2>&1; then
                USE_SUDO=1
            else
                USE_SUDO=0
            fi
            ;;
        1|true|yes)
            USE_SUDO=1
            ;;
        0|false|no)
            USE_SUDO=0
            ;;
        *)
            echo "Error: USE_SUDO must be one of: auto, 1, 0"
            exit 1
            ;;
    esac

    if [[ "$USE_SUDO" == "1" ]] && ! sudo -n true >/dev/null 2>&1; then
        echo "Error: USE_SUDO=1 but passwordless sudo is unavailable."
        exit 1
    fi

    # Disk numbers
    DISK_NUM="$(lsblk -dn -o MAJ:MIN "$DEV_NAME" 2>/dev/null | head -n 1)"
    if [[ -z "$DISK_NUM" ]]; then
        if [[ "$USE_SUDO" == "1" ]]; then
            echo "Error: Failed to resolve major:minor for $DEV_NAME (lsblk unavailable?)"
            exit 1
        fi
        DISK_NUM="0:0"
    fi
    # shellcheck disable=SC2034
    STAT_DISK_NUM="$DISK_NUM"
    BG_DISK_NUM="${BG_DISK_NUM:-0:0}"

    local _fs
    for _fs in $FS_TYPES; do
        case "$_fs" in
            ext4|xfs) ;;
            *)
                echo "Error: FS_TYPES must contain only: ext4, xfs (got '$_fs')"
                exit 1
                ;;
        esac
    done

    local default_property_file
    local default_db_path
    case "$DB_NAME" in
        rocksdb)
            default_property_file="./rocksdb/rocksdb.properties"
            default_db_path="$MOUNT_POINT/rocksdb"
            DB_PATH_PROP_KEY="rocksdb.dbname"
            DB_HAS_MANIFEST=1
            ;;
        leveldb)
            default_property_file="./leveldb/leveldb.properties"
            default_db_path="$MOUNT_POINT/leveldb"
            DB_PATH_PROP_KEY="leveldb.dbname"
            DB_HAS_MANIFEST=1
            ;;
        sqlite)
            default_property_file="./sqlite/sqlite.properties"
            default_db_path="$MOUNT_POINT/sqlite/ycsb.db"
            DB_PATH_PROP_KEY="sqlite.dbpath"
            DB_HAS_MANIFEST=0
            ;;
        *)
            echo "Error: Unsupported DB_NAME '$DB_NAME'. Supported: rocksdb, leveldb, sqlite"
            exit 1
            ;;
    esac

    DB_PROPERTY_FILE="${DB_PROPERTY_FILE:-$default_property_file}"
    if [[ -z "$DB_PATH" && "$USE_SUDO" == "0" ]]; then
        case "$DB_NAME" in
            rocksdb) DB_PATH="/tmp/ycsb-rocksdb" ;;
            leveldb) DB_PATH="/tmp/ycsb-leveldb" ;;
            sqlite) DB_PATH="/tmp/ycsb-sqlite/ycsb.db" ;;
        esac
    else
        DB_PATH="${DB_PATH:-$default_db_path}"
    fi
    if [[ ! -f "$DB_PROPERTY_FILE" ]]; then
        echo "Warning: DB property file '$DB_PROPERTY_FILE' not found. Continuing without -P."
        DB_PROPERTY_FILE=""
    fi
}

# --- Common Initialization ---

init_run() {
    mkdir -p "$OUTPUT_DIR"
    mkdir -p "$RUN_STATS_DIR"

    echo "Starting YCSB-cpp Workloads..."
    echo "Database: $DB_NAME"
    echo "DB Path: $DB_PATH"
    echo "Device: $DEV_NAME, Mount: $MOUNT_POINT, FS: $FS_TYPES"
    echo "Output: $OUTPUT_DIR"
    echo "Per-run stats tables: $RUN_STATS_DIR"
    echo "--------------------------------------------------"

    if [[ ! -x "$YCSB_EXEC" ]]; then
        echo "Warning: YCSB executable '$YCSB_EXEC' not found or not executable."
        echo "Please ensure YCSB-cpp is built and the path is correct."
    fi

    print_summary_header "$SUMMARY_FILE"

    if [[ "$USE_SUDO" == "1" ]]; then
        run_privileged true
    else
        echo "Running in non-sudo mode: mount/umount and privileged sysfs/stat collection will be skipped."
    fi
    write_sysfs 1 /sys/kernel/stats/thread_init
}

# --- Common Main Loop ---
#
# The calling script must define these functions before calling run_all_workloads:
#   configure_for_load    - called before the load phase
#   configure_for_run     - called before the run phase
#   run_ycsb <workload>   - run YCSB and set YCSB_OUTPUT
#   post_run_hook         - called after parsing stats (optional, default no-op)

# Default no-op for post_run_hook (scripts can override)
post_run_hook() { :; }

run_all_workloads() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    for FS_TYPE in $FS_TYPES; do
        echo "============================================================"
        echo "# Filesystem: $FS_TYPE"
        echo "============================================================"

    for tc in $THREAD_COUNTS; do
        echo "############################################################"
        echo "# Thread Count: $tc (FS: $FS_TYPE)"
        echo "############################################################"

        # Regenerate workload files with this thread count
        THREADCOUNT="$tc" bash "$script_dir/gen_workloads.sh"

        for workload in $WORKLOADS; do
            echo "===== Processing Workload: ${workload} (threads=$tc, fs=$FS_TYPE) ====="

            # Initialize per-workload accumulators
            total_throughput=0
            total_write_time_ns=0
            total_write_count=0
            total_write_4k_time_ns=0
            total_write_4k_count=0
            total_filemap_read_time_ns=0
            total_filemap_read_count=0
            total_filemap_fsync_time_ns=0
            total_filemap_fsync_count=0
            total_copy_time_ns=0
            total_copy_count=0
            total_fadvise_time_ns=0
            total_fadvise_count=0
            total_cpu_usage_percent=0
            local min_throughput=""
            local max_throughput=""
            local workload_op_summary_tsv="$RUN_STATS_DIR/workload_${workload}_${FS_TYPE}_t${tc}_op_stats_all_runs.tsv"
            : > "$workload_op_summary_tsv"

            # Unmount if needed
            if [[ "$USE_SUDO" == "1" ]] && mountpoint -q "$MOUNT_POINT"; then
                run_privileged umount "$MOUNT_POINT"
            fi

            for i in $(seq 1 "$NUM_RUNS"); do
                echo "--- Run $i / $NUM_RUNS ---"

		echo 3 | sudo tee /proc/sys/vm/drop_caches

                # 1. Load phase
                configure_for_load

                echo "Loading data..."
                if [[ "$USE_SUDO" == "1" ]]; then
                    format_and_mount
                fi
                clean_database_path

                local -a load_cmd
                build_ycsb_command load "$workload" load_cmd
                "${load_cmd[@]}" >"/tmp/ycsb_cpp_load_w${workload}_${FS_TYPE}_t${tc}_run${i}.log" 2>&1
                echo "Load complete."

                # 2. Run phase
                configure_for_run
                set_manifest_ignore_inode

                LOG_FILE="$OUTPUT_DIR/workload_${workload}_${FS_TYPE}_t${tc}_run_${i}.log"
                echo "Running workload (Logging to $LOG_FILE)..."

                # Start iostat
                local iostat_pid=""
                iostat -x "$DEV_NAME" -h -o JSON 1 >"$OUTPUT_DIR/iostat_workload_${workload}_${FS_TYPE}_t${tc}_run_${i}.log" &
                iostat_pid=$!

                # Run YCSB (script-specific)
                local cpu_start_total=0
                local cpu_start_idle=0
                local cpu_end_total=0
                local cpu_end_idle=0
                local run_cpu_usage_percent="0"
                if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
                    read_cpu_jiffies cpu_start_total cpu_start_idle || true
                fi

                set +e
                run_ycsb "$workload"
                local run_rc=$?
                stop_iostat "$iostat_pid"
                set -e

                if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
                    if read_cpu_jiffies cpu_end_total cpu_end_idle; then
                        run_cpu_usage_percent="$(calculate_cpu_usage_percent \
                            "$cpu_start_total" "$cpu_start_idle" \
                            "$cpu_end_total" "$cpu_end_idle")"
                    fi
                    total_cpu_usage_percent="$(echo "$total_cpu_usage_percent + $run_cpu_usage_percent" | bc)"
                    echo "  -> Avg System CPU Usage: $run_cpu_usage_percent %"
                fi

                if [[ "$run_rc" -ne 0 ]]; then
                    echo "Error: YCSB run failed (workload=${workload}, threads=${tc}, fs=${FS_TYPE}, run=${i})"
                    return "$run_rc"
                fi

                # Collect and log stats
                if [[ -r "$STATS_FILE" ]]; then
                    STATS="$(cat "$STATS_FILE")"
                elif [[ "$USE_SUDO" == "1" ]]; then
                    STATS="$(run_privileged cat "$STATS_FILE" 2>/dev/null || true)"
                else
                    STATS=""
                fi

                {
                    echo "===== Workload: $workload, FS: $FS_TYPE, Threads: $tc, Run: $i ====="
                    echo "--- YCSB Output ---"
                    echo "$YCSB_OUTPUT"
                    echo "--- Kernel Stats ---"
                    echo "$STATS"
                    if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
                        echo "--- Runtime Stats ---"
                        echo "avg_system_cpu_usage_percent: $run_cpu_usage_percent"
                    fi
                    echo "======================================="
                    echo ""
                } > "$LOG_FILE"

                # Parse throughput
                throughput="$(echo "$YCSB_OUTPUT" | awk -F: '/Run throughput\(ops\/sec\):/ {gsub(/ /, "", $2); print $2; exit}')"
                if [[ -z "$throughput" ]]; then
                    throughput="$(echo "$YCSB_OUTPUT" | awk -F, '/\[OVERALL\], Throughput/ {gsub(/ /, "", $3); print $3; exit}')"
                fi
                if [[ -z "$throughput" ]]; then
                    throughput=0
                fi
                total_throughput="$(echo "$total_throughput + $throughput" | bc)"
                if [[ -z "$min_throughput" ]] || float_lt "$throughput" "$min_throughput"; then
                    min_throughput="$throughput"
                fi
                if [[ -z "$max_throughput" ]] || float_gt "$throughput" "$max_throughput"; then
                    max_throughput="$throughput"
                fi
                echo "  -> Throughput: $throughput ops/sec"

                local run_op_stats_tsv="$RUN_STATS_DIR/workload_${workload}_${FS_TYPE}_t${tc}_run_${i}_op_stats.tsv"
                local run_op_stats_table="$RUN_STATS_DIR/workload_${workload}_${FS_TYPE}_t${tc}_run_${i}_op_stats_table.log"
                parse_ycsb_operation_metrics "$YCSB_OUTPUT" > "$run_op_stats_tsv"
                if [[ -s "$run_op_stats_tsv" ]]; then
                    print_run_operation_table "$run_op_stats_tsv" "$run_op_stats_table" "$workload" "$tc" "$i"
                    awk -F'\t' -v run_id="$i" 'BEGIN { OFS="\t" } NF >= 9 { print run_id, $0 }' "$run_op_stats_tsv" >> "$workload_op_summary_tsv"
                    echo "  -> Operation table: $run_op_stats_table"
                else
                    echo "  -> Warning: Could not parse per-operation metrics for run $i."
                fi

                # Parse kernel stats
		parse_and_aggregate_kernel_stats "vfs_write_time" "vfs_write_count" "write_call_time_ns" "write_call_count"
                parse_and_aggregate_kernel_stats "perform_write_time" "perform_write_count" "total_write_time_ns" "total_write_count"
                parse_and_aggregate_kernel_stats "perform_write_4k_time" "perform_write_4k_count" "total_write_4k_time_ns" "total_write_4k_count"
                parse_and_aggregate_kernel_stats "filemap_read_time" "filemap_read_count" "total_filemap_read_time_ns" "total_filemap_read_count"
                parse_and_aggregate_kernel_stats "filemap_fsync_time" "filemap_fsync_count" "total_filemap_fsync_time_ns" "total_filemap_fsync_count"
                parse_and_aggregate_kernel_stats "copy_time" "copy_count" "total_copy_time_ns" "total_copy_count"
                parse_and_aggregate_kernel_stats "fadvise_time" "fadvise_count" "total_fadvise_time_ns" "total_fadvise_count"

                # Save workload file
                cp "$WORKLOAD_DIR/workload$workload" "$OUTPUT_DIR/workload${workload}_${FS_TYPE}_t${tc}_run${i}.workload" 2>/dev/null || true

                # Save RocksDB LOG (stall reasons, compaction stats) before teardown
                if [[ "$DB_NAME" == "rocksdb" && -f "$DB_PATH/LOG" ]]; then
                    cp "$DB_PATH/LOG" "$OUTPUT_DIR/rocksdb_LOG_${workload}_${FS_TYPE}_t${tc}_run${i}" 2>/dev/null || true
                fi

                # Script-specific post-run actions
                post_run_hook

                if [[ "$USE_SUDO" == "1" ]] && mountpoint -q "$MOUNT_POINT"; then
                    run_privileged umount "$MOUNT_POINT"
                fi
            done

            # Print summary
            local avg_throughput
            avg_throughput="$(calculate_average "$total_throughput" "$NUM_RUNS")"
            local avg_cpu_usage_percent
            if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
                avg_cpu_usage_percent="$(calculate_average "$total_cpu_usage_percent" "$NUM_RUNS")"
            fi

            for target in "/dev/stdout" "$SUMMARY_FILE"; do
                {
                    echo "--------------------------------------------------"
                    echo "Workload '$workload' (fs=$FS_TYPE, threads=$tc) Averages ($NUM_RUNS runs)"
                    printf "% -30s %15s\n" "Metric" "Value"
                    printf "% -30s %15s\n" "------------------------------" "---------------"
                    printf "% -30s %15.2f %s\n" "Minimum Throughput" "$min_throughput" "ops/sec"
                    printf "% -30s %15.2f %s\n" "Maximum Throughput" "$max_throughput" "ops/sec"
                    printf "% -30s %15.2f %s\n" "Average Throughput" "$avg_throughput" "ops/sec"
                    if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
                        printf "% -30s %15.2f %s\n" "Average System CPU Usage" "$avg_cpu_usage_percent" "%"
                    fi
                    echo ""
                    if [[ -s "$workload_op_summary_tsv" ]]; then
                        print_operation_summary_table "$workload_op_summary_tsv"
                    fi

		    print_metric_stats "Write syscall" "$write_call_time_ns" "$write_call_count"
                    print_metric_stats "Perform Write" "$total_write_time_ns" "$total_write_count"
                    print_metric_stats "Perform Write 4K" "$total_write_4k_time_ns" "$total_write_4k_count"
                    print_metric_stats "Filemap Read" "$total_filemap_read_time_ns" "$total_filemap_read_count"
                    print_metric_stats "Filemap Fsync" "$total_filemap_fsync_time_ns" "$total_filemap_fsync_count"
                    print_metric_stats "Copy" "$total_copy_time_ns" "$total_copy_count"
                    print_metric_stats "Fadvise" "$total_fadvise_time_ns" "$total_fadvise_count"

                    echo "--------------------------------------------------"
                    echo ""
                } >> "$target"
            done
        done
    done

    done  # FS_TYPES

    echo "===== All workloads complete. ====="
    echo "Summary saved to: $SUMMARY_FILE"
}
