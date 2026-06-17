#!/usr/bin/env bash
# common.sh - Shared configuration and functions for log4j2 benchmark scripts.
#
# Source this file from your run script, set script-specific variables,
# then call load_config, init_run, and run_all_benchmarks.

# --- Default Configuration (override before calling load_config) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AE_ROOT="${AE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR/java-logger-benchmark}"
if [[ -n "${AE_JAVA_HOME:-}" ]]; then
    JAVA_HOME="$AE_JAVA_HOME"
elif [[ -n "${JAVA_HOME:-}" ]]; then
    JAVA_HOME="$JAVA_HOME"
else
    JAVA_BIN="$(command -v java 2>/dev/null || true)"
    if [[ -n "$JAVA_BIN" ]]; then
        JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$JAVA_BIN")")")"
    else
        JAVA_HOME=""
    fi
fi
JAVA_CMD="${AE_JAVA_CMD:-${JAVA_HOME:+$JAVA_HOME/bin/java}}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/pmem}"
DEV_NAME="${DEV_NAME:-/dev/nvme0n1}"
STATS_FILE="${STATS_FILE:-/sys/kernel/stats/stats}"
CPU_AFFINITY="${CPU_AFFINITY:-0-79}"
FS_TYPE="${FS_TYPE:-xfs ext4}"
USE_SUDO="${USE_SUDO:-1}"
RUN_USER="${RUN_USER:-$(id -un)}"
RUN_GROUP="${RUN_GROUP:-$(id -gn)}"
REPORT_SYSTEM_CPU_USAGE="${REPORT_SYSTEM_CPU_USAGE:-1}"
LOG4J_DRAIN_DIRTY_PAGES="${LOG4J_DRAIN_DIRTY_PAGES:-1}"
LOG4J_DIRTY_MAX_KB="${LOG4J_DIRTY_MAX_KB:-1048576}"
LOG4J_WRITEBACK_MAX_KB="${LOG4J_WRITEBACK_MAX_KB:-0}"
LOG4J_DIRTY_DRAIN_TIMEOUT_SEC="${LOG4J_DIRTY_DRAIN_TIMEOUT_SEC:-180}"

# JMH settings
NUM_RUNS="${NUM_RUNS:-3}"
JMH_FORKS="${JMH_FORKS:-1}"
JMH_THREADS="${JMH_THREADS:-4}"
WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-3}"
WARMUP_TIME="${WARMUP_TIME:-5s}"
MEASUREMENT_ITERATIONS="${MEASUREMENT_ITERATIONS:-5}"
MEASUREMENT_TIME="${MEASUREMENT_TIME:-30s}"
LOGGING_TYPES="${LOGGING_TYPES:-FILE}"
JMH_BENCHMARK="${JMH_BENCHMARK:-Log4JLoggerBenchmark}"
JMH_EXTRA_ARGS="${JMH_EXTRA_ARGS:-}"

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
        local current=""
        if [[ "$USE_SUDO" == "1" ]]; then
            current="$(run_privileged cat "$path" 2>/dev/null | head -n 1 || true)"
        else
            current="$(cat "$path" 2>/dev/null | head -n 1 || true)"
        fi
        if [[ "$current" == "$value" ]]; then
            return
        fi
        if [[ -w "$path" ]]; then
            printf "%s\n" "$value" >"$path" 2>/dev/null || true
        elif [[ "$USE_SUDO" == "1" ]]; then
            printf "%s\n" "$value" | run_privileged tee "$path" >/dev/null 2>/dev/null || true
        fi
    fi
}

format_disk_ext4() { run_privileged mkfs.ext4 -F "$1"; }
format_disk_xfs()  { run_privileged mkfs.xfs -f "$1"; }

parse_fs_types() {
    local raw_fs_types="${FS_TYPE//,/ }"
    local fs_type

    FS_TYPES=()
    for fs_type in $raw_fs_types; do
        if ! declare -f "format_disk_${fs_type}" >/dev/null 2>&1; then
            echo "Error: Unsupported filesystem type '$fs_type'"
            exit 1
        fi
        FS_TYPES+=("$fs_type")
    done

    if [[ "${#FS_TYPES[@]}" -eq 0 ]]; then
        echo "Error: FS_TYPE must contain at least one filesystem type"
        exit 1
    fi

    FS_TYPE_DISPLAY="${FS_TYPES[*]}"
}

format_and_mount() {
    local fs_type="${1:-$CURRENT_FS_TYPE}"
    if [[ "$USE_SUDO" != "1" ]]; then
        return
    fi
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        run_privileged umount "$MOUNT_POINT"
    fi
    "format_disk_${fs_type}" "$DEV_NAME"
    run_privileged mount "$DEV_NAME" "$MOUNT_POINT"
    run_privileged chown -R "$RUN_USER:$RUN_GROUP" "$MOUNT_POINT"
}

read_cpu_jiffies() {
    local total_var="$1"
    local idle_var="$2"
    local total=0 idle=0
    if ! read -r total idle < <(awk '
        /^cpu / { print ($2+$3+$4+$5+$6+$7+$8+$9), ($5+$6); found=1; exit }
        END { if (!found) exit 1 }
    ' /proc/stat 2>/dev/null); then
        eval "$total_var=0; $idle_var=0"
        return 1
    fi
    eval "$total_var=$total; $idle_var=$idle"
}

calculate_cpu_usage_percent() {
    local dt=$(($3 - $1))
    local di=$(($4 - $2))
    if (( dt <= 0 )); then echo "0"; return; fi
    awk -v dt="$dt" -v di="$di" 'BEGIN { u=((dt-di)*100)/dt; if(u<0)u=0; if(u>100)u=100; printf "%.2f",u }'
}

calculate_average() {
    local total="$1" count="$2"
    if [[ "$count" -gt 0 ]]; then
        echo "scale=2; $total / $count" | bc
    else
        echo "0"
    fi
}

float_lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
float_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

read_dirty_writeback_kb() {
    awk '
        /^Dirty:/ { dirty=$2 }
        /^Writeback:/ { writeback=$2 }
        END {
            if (dirty == "") dirty = 0
            if (writeback == "") writeback = 0
            print dirty, writeback
        }
    ' /proc/meminfo
}

wait_for_dirty_drain() {
    local reason="${1:-dirty drain}"
    local dirty=0 writeback=0
    local deadline=$((SECONDS + LOG4J_DIRTY_DRAIN_TIMEOUT_SEC))

    if [[ "$LOG4J_DRAIN_DIRTY_PAGES" != "1" ]]; then
        return 0
    fi

    while true; do
        read -r dirty writeback < <(read_dirty_writeback_kb)
        if (( dirty <= LOG4J_DIRTY_MAX_KB && writeback <= LOG4J_WRITEBACK_MAX_KB )); then
            return 0
        fi
        if (( SECONDS >= deadline )); then
            echo "  Warning: dirty drain timeout after $LOG4J_DIRTY_DRAIN_TIMEOUT_SEC sec ($reason): Dirty=${dirty}kB Writeback=${writeback}kB"
            return 1
        fi
        sleep 2
    done
}

drain_dirty_pages() {
    local reason="${1:-post-run}"

    if [[ "$LOG4J_DRAIN_DIRTY_PAGES" != "1" ]]; then
        return 0
    fi

    sync || true
    wait_for_dirty_drain "$reason" || true
}

# --- JMH Execution ---

build_jmh_classpath() {
    local cp_file="$REPO_DIR/jmh-benchmarks/target/cp.txt"
    local dep_dir="$REPO_DIR/jmh-benchmarks/target/dependency"
    if [[ -d "$dep_dir" ]]; then
        local dep_cp=""
        local jar
        while IFS= read -r jar; do
            dep_cp="${dep_cp:+$dep_cp:}$jar"
        done < <(find "$dep_dir" -maxdepth 1 -type f -name '*.jar' | sort)
        JMH_CLASSPATH="$REPO_DIR/jmh-benchmarks/target/test-classes:$REPO_DIR/jmh-benchmarks/target/classes:$dep_cp"
    else
        if [[ ! -f "$cp_file" ]]; then
            echo "Error: Log4j benchmark classpath not found. Run the Maven preparation commands in README.md first."
            exit 1
        fi
        JMH_CLASSPATH="$REPO_DIR/jmh-benchmarks/target/test-classes:$REPO_DIR/jmh-benchmarks/target/classes:$(cat "$cp_file")"
    fi
}

run_jmh() {
    local run_id="$1"
    local json_file="$OUTPUT_DIR/run_${run_id}_results.json"
    local log_file="$OUTPUT_DIR/run_${run_id}_jmh.log"
    local logging_types="$LOGGING_TYPES"
    if [[ "$logging_types" == "%FS%" ]]; then
        logging_types="$CURRENT_FS_TYPE"
    fi

    local -a cmd=()
    if [[ "${PERF_PROFILE:-0}" == "1" ]]; then
        cmd+=( sudo "${LINUX_DIR:-$HOME/linux}/tools/perf/perf" record --strict-freq --kcore -e 'cpu/cycles/ppp' -a -g -F2000 \
               -o "$OUTPUT_DIR/perf_run_${run_id}.data" -- )
    fi
    cmd+=(
        taskset -c "$CPU_AFFINITY"
        "$JAVA_CMD" -cp "$JMH_CLASSPATH"
        org.openjdk.jmh.Main
        "$JMH_BENCHMARK"
        -p "loggingType=$logging_types"
        -wi "$WARMUP_ITERATIONS" -w "$WARMUP_TIME"
        -i "$MEASUREMENT_ITERATIONS" -r "$MEASUREMENT_TIME"
        -t "$JMH_THREADS" -f "$JMH_FORKS"
        -rf json -rff "$json_file"
        -jvmArgs "-Dlog.output.dir=$LOG_OUTPUT_DIR"
    )

    if [[ -n "$JMH_EXTRA_ARGS" ]]; then
        # shellcheck disable=SC2206
        cmd+=( $JMH_EXTRA_ARGS )
    fi

    echo "  JMH command: ${cmd[*]}"
    exec 3>&1
    JMH_OUTPUT=$("${cmd[@]}" 2>&1 | tee /dev/fd/3)
    exec 3>&-

    echo "$JMH_OUTPUT" > "$log_file"
}

# --- Result Parsing ---

parse_jmh_text_results() {
    local jmh_output="$1"
    # Extract the result table lines (benchmark results)
    echo "$jmh_output" | awk '
        /^Benchmark / { header=1; print; next }
        header && /^[A-Za-z]/ { print }
    '
}

parse_jmh_json_throughput() {
    local json_file="$1"
    # Extract benchmark name, params, score, and error from JSON
    if command -v python3 &>/dev/null; then
        python3 - "$json_file" << 'PYEOF'
import json, sys, math
with open(sys.argv[1]) as f:
    data = json.load(f)
for r in data:
    name = r['benchmark'].split('.')[-1]
    params = r.get('params', {})
    lt = params.get('loggingType', '?')
    score = float(r['primaryMetric']['score'])
    err = r['primaryMetric']['scoreError']
    try:
        err = float(err)
        if math.isnan(err):
            err = 0.0
    except (ValueError, TypeError):
        err = 0.0
    unit = r['primaryMetric']['scoreUnit']
    print(f'{name}\t{lt}\t{score:.2f}\t{err:.2f}\t{unit}')
PYEOF
    fi
}

print_run_summary() {
    local run_id="$1"
    local json_file="$OUTPUT_DIR/run_${run_id}_results.json"

    if [[ ! -f "$json_file" ]]; then
        echo "  Warning: No JSON results for run $run_id"
        return
    fi

    echo "  --- Run $run_id Results ---"
    printf "  %-40s %-20s %16s %12s %s\n" "Benchmark" "LoggingType" "Score" "Error" "Unit"
    printf "  %-40s %-20s %16s %12s %s\n" "----------------------------------------" "--------------------" "----------------" "------------" "-----"
    parse_jmh_json_throughput "$json_file" | while IFS=$'\t' read -r name lt score error unit; do
        printf "  %-40s %-20s %16s %12s %s\n" "$name" "$lt" "$score" "+/- $error" "$unit"
    done
    echo ""
}

print_aggregate_summary() {
    local summary_tsv="$OUTPUT_DIR/all_runs_summary.tsv"
    : > "$summary_tsv"

    # Collect all JSON results
    for i in $(seq 1 "$NUM_RUNS"); do
        local json_file="$OUTPUT_DIR/run_${i}_results.json"
        if [[ -f "$json_file" ]]; then
            parse_jmh_json_throughput "$json_file" | while IFS=$'\t' read -r name lt score error unit; do
                printf "%d\t%s\t%s\t%s\t%s\t%s\n" "$i" "$name" "$lt" "$score" "$error" "$unit" >> "$summary_tsv"
            done
        fi
    done

    if [[ ! -s "$summary_tsv" ]]; then
        echo "No results to aggregate."
        return
    fi

    echo "===== Aggregate Results (across $NUM_RUNS runs) ====="
    printf "%-40s %-20s %10s %16s %16s %16s\n" \
        "Benchmark" "LoggingType" "Runs" "Min(ops/s)" "Max(ops/s)" "Avg(ops/s)"
    printf "%-40s %-20s %10s %16s %16s %16s\n" \
        "----------------------------------------" "--------------------" "----------" "----------------" "----------------" "----------------"

    awk -F'\t' '
    {
        key = $2 SUBSEP $3
        score = $4 + 0
        if (!(key in count)) {
            count[key] = 0
            total[key] = 0
            min_s[key] = score
            max_s[key] = score
            name[key] = $2
            lt[key] = $3
        }
        count[key]++
        total[key] += score
        if (score < min_s[key]) min_s[key] = score
        if (score > max_s[key]) max_s[key] = score
    }
    END {
        for (k in count) {
            avg = total[k] / count[k]
            printf "%s\t%s\t%d\t%.2f\t%.2f\t%.2f\n",
                name[k], lt[k], count[k], min_s[k], max_s[k], avg
        }
    }' "$summary_tsv" | sort -t$'\t' -k1,1 -k2,2 | while IFS=$'\t' read -r name lt runs mn mx avg; do
        printf "%-40s %-20s %10d %16.2f %16.2f %16.2f\n" "$name" "$lt" "$runs" "$mn" "$mx" "$avg"
    done
    echo ""
}

# --- Kernel Stats ---

parse_and_aggregate_kernel_stats() {
    local key_time="$1" key_count="$2" total_time_var="$3" total_count_var="$4"
    local time count
    time="$(echo "$STATS" | awk -F'[:,]' -v key="$key_time" '$0 ~ key {gsub(/ /, "", $2); print $2; exit}')"
    count="$(echo "$STATS" | awk -F'[:,]' -v key="$key_count" '$0 ~ key {gsub(/ /, "", $4); print $4; exit}')"
    [[ -z "$time" ]] && time=0
    [[ -z "$count" ]] && count=0
    eval "$total_time_var=\$(( \${$total_time_var:-0} + $time ))"
    eval "$total_count_var=\$(( \${$total_count_var:-0} + $count ))"
}

print_metric_stats() {
    local title="$1" time="$2" count="$3"
    local avg
    avg="$(calculate_average "$time" "$count")"
    printf "  %-30s %15s\n" "--- $title ---" ""
    printf "  %-30s %15d\n" "Total Time (ns)" "$time"
    printf "  %-30s %15d\n" "Total Count" "$count"
    printf "  %-30s %15.2f %s\n" "Avg Latency" "$avg" "ns"
    echo ""
}

# --- Configuration ---

load_config() {
    BASE_OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output/log4j2_$(date +"%Y-%m-%d_%H-%M-%S")}"
    OUTPUT_DIR="$BASE_OUTPUT_DIR"
    SUMMARY_FILE="$BASE_OUTPUT_DIR/summary.log"

    case "$USE_SUDO" in
        auto)
            if sudo -n true >/dev/null 2>&1; then USE_SUDO=1; else USE_SUDO=0; fi ;;
        1|true|yes) USE_SUDO=1 ;;
        0|false|no) USE_SUDO=0 ;;
        *) echo "Error: USE_SUDO must be one of: auto, 1, 0"; exit 1 ;;
    esac

    if [[ "$USE_SUDO" == "1" ]] && ! sudo -n true >/dev/null 2>&1; then
        echo "Error: USE_SUDO=1 but passwordless sudo is unavailable."
        exit 1
    fi

    # Disk numbers for kernel stats
    DISK_NUM="$(lsblk -rno PATH,MAJ:MIN 2>/dev/null | awk -v dev="$DEV_NAME" '$1 == dev { print $2; found=1; exit } END { exit found ? 0 : 1 }')"
    if [[ -z "$DISK_NUM" ]]; then
        if [[ "$USE_SUDO" == "1" ]]; then
            echo "Error: Failed to resolve major:minor for $DEV_NAME"
            exit 1
        fi
        DISK_NUM="0:0"
    fi
    STAT_DISK_NUM="$DISK_NUM"
    BG_DISK_NUM="${BG_DISK_NUM:-0:0}"

    # Log output directory
    if [[ "$USE_SUDO" == "1" ]]; then
        LOG_OUTPUT_DIR="$MOUNT_POINT/log_output"
    else
        LOG_OUTPUT_DIR="${LOG_OUTPUT_DIR:-/tmp/log_bench_output}"
    fi

    parse_fs_types
    build_jmh_classpath
}

# --- Initialization ---

init_run() {
    mkdir -p "$BASE_OUTPUT_DIR"

    echo "Starting Log4j2 Benchmark..."
    echo "Mode: $BENCH_MODE"
    echo "Device: $DEV_NAME, Mount: $MOUNT_POINT, FS: $FS_TYPE_DISPLAY"
    echo "Log output dir: $LOG_OUTPUT_DIR"
    echo "JMH: forks=$JMH_FORKS threads=$JMH_THREADS warmup=${WARMUP_ITERATIONS}x${WARMUP_TIME} measure=${MEASUREMENT_ITERATIONS}x${MEASUREMENT_TIME}"
    echo "Logging types: $LOGGING_TYPES"
    echo "Runs per filesystem: $NUM_RUNS"
    echo "Output root: $BASE_OUTPUT_DIR"
    echo "--------------------------------------------------"

    {
        echo "===== Log4j2 Benchmark Summary ====="
        echo "Mode: $BENCH_MODE"
        echo "Timestamp: $(date)"
        echo "======================================="
        echo ""
    } > "$SUMMARY_FILE"

    if [[ "$USE_SUDO" == "1" ]]; then
        run_privileged true
    else
        echo "Running in non-sudo mode: mount/format skipped, logging to $LOG_OUTPUT_DIR"
    fi
    write_sysfs 1 /sys/kernel/stats/thread_init
}

# --- Main Loop ---
# Calling script must define: configure_for_run()

reset_aggregate_metrics() {
    total_write_call_time_ns=0
    total_write_call_count=0
    total_write_time_ns=0
    total_write_count=0
    total_fsync_time_ns=0
    total_fsync_count=0
    total_copy_time_ns=0
    total_copy_count=0
}

run_all_benchmarks() {
    local total_cpu_usage_percent=0
    local fs_type

    for fs_type in "${FS_TYPES[@]}"; do
        CURRENT_FS_TYPE="$fs_type"
        OUTPUT_DIR="$BASE_OUTPUT_DIR/$CURRENT_FS_TYPE"
        mkdir -p "$OUTPUT_DIR"
        reset_aggregate_metrics
        total_cpu_usage_percent=0

        echo ""
        echo "===== Filesystem: $CURRENT_FS_TYPE ====="
        echo "Results: $OUTPUT_DIR/"

        {
            echo "===== Filesystem: $CURRENT_FS_TYPE ====="
            echo "Results: $OUTPUT_DIR/"
            echo ""
        } >> "$SUMMARY_FILE"

        for i in $(seq 1 "$NUM_RUNS"); do
            echo ""
            echo "===== Filesystem $CURRENT_FS_TYPE: Run $i / $NUM_RUNS ====="

            wait_for_dirty_drain "before $CURRENT_FS_TYPE run $i" || true

            # Format and mount fresh filesystem
            if [[ "$USE_SUDO" == "1" ]]; then
                format_and_mount "$CURRENT_FS_TYPE"
                mkdir -p "$LOG_OUTPUT_DIR"
            else
                mkdir -p "$LOG_OUTPUT_DIR"
                rm -f "$LOG_OUTPUT_DIR"/log4j-*.log
            fi

            # Configure kernel for this mode
            configure_for_run

            # Clear kernel stats
            write_sysfs "$STAT_DISK_NUM" /sys/kernel/stats/stats_allowed_dev_name
            write_sysfs 0 "$STATS_FILE"

            # Start CPU monitoring
            local cpu_s_total=0 cpu_s_idle=0 cpu_e_total=0 cpu_e_idle=0
            local run_cpu="0"
            if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
                read_cpu_jiffies cpu_s_total cpu_s_idle || true
            fi

            # Run JMH benchmark
            set +e
            run_jmh "$i"
            local rc=$?
            set -e

            # CPU usage
            if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
                if read_cpu_jiffies cpu_e_total cpu_e_idle; then
                    run_cpu="$(calculate_cpu_usage_percent "$cpu_s_total" "$cpu_s_idle" "$cpu_e_total" "$cpu_e_idle")"
                fi
                total_cpu_usage_percent="$(echo "$total_cpu_usage_percent + $run_cpu" | bc)"
                echo "  -> Avg System CPU Usage: $run_cpu %"
            fi

            # Collect kernel stats
            if [[ -r "$STATS_FILE" ]]; then
                STATS="$(cat "$STATS_FILE")"
            elif [[ "$USE_SUDO" == "1" ]]; then
                STATS="$(run_privileged cat "$STATS_FILE" 2>/dev/null || true)"
            else
                STATS=""
            fi

            # Save kernel stats
            {
                echo "===== Run $i Kernel Stats ====="
                echo "filesystem: $CURRENT_FS_TYPE"
                echo "$STATS"
                if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
                    echo "avg_system_cpu_usage_percent: $run_cpu"
                fi
                echo ""
            } > "$OUTPUT_DIR/run_${i}_kernel_stats.log"

            # Parse kernel stats
            parse_and_aggregate_kernel_stats "vfs_write_time" "vfs_write_count" "total_write_call_time_ns" "total_write_call_count"
            parse_and_aggregate_kernel_stats "perform_write_time" "perform_write_count" "total_write_time_ns" "total_write_count"
            parse_and_aggregate_kernel_stats "fsync_range_time" "fsync_range_count" "total_fsync_time_ns" "total_fsync_count"
            parse_and_aggregate_kernel_stats "copy_time" "copy_count" "total_copy_time_ns" "total_copy_count"

            # Print per-run results
            print_run_summary "$i"

            # Post-run hook (optional, defined by calling script)
            if declare -f post_run_hook >/dev/null 2>&1; then
                post_run_hook
            fi

            drain_dirty_pages "after $CURRENT_FS_TYPE run $i"

            # Unmount
            if [[ "$USE_SUDO" == "1" ]] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
                run_privileged umount "$MOUNT_POINT"
            fi

        done

        # --- Aggregate Summary ---
        echo ""
        echo "=================================================="

        local avg_cpu=""
        if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
            avg_cpu="$(calculate_average "$total_cpu_usage_percent" "$NUM_RUNS")"
        fi

        {
            print_aggregate_summary

            if [[ "$REPORT_SYSTEM_CPU_USAGE" == "1" ]]; then
                printf "Average System CPU Usage: %s %%\n\n" "$avg_cpu"
            fi

            echo "--- Kernel Stats (aggregated across $NUM_RUNS runs) ---"
            print_metric_stats "Write Syscall" "${total_write_call_time_ns:-0}" "${total_write_call_count:-0}"
            print_metric_stats "Perform Write" "${total_write_time_ns:-0}" "${total_write_count:-0}"
            print_metric_stats "Fsync" "${total_fsync_time_ns:-0}" "${total_fsync_count:-0}"
            print_metric_stats "Copy" "${total_copy_time_ns:-0}" "${total_copy_count:-0}"
            echo "--------------------------------------------------"
            echo ""
        } | tee -a "$SUMMARY_FILE"
    done

    echo ""
    echo "===== All runs complete. ====="
    echo "Summary: $SUMMARY_FILE"
    echo "Results: $BASE_OUTPUT_DIR/"
}
