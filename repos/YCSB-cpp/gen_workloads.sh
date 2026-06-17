#!/bin/bash
#
# gen_workloads.sh - Generate all YCSB workload files
#
# Usage: ./gen_workloads.sh
#
# Modify the shared variables below, then re-run to regenerate
# all workload files without editing each one individually.

set -e

WORKLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workloads"

# ============================================================
# Shared settings - change here to update ALL workloads
# ============================================================
RECORD_COUNT=10000000
OPERATION_COUNT=10000000
WORKLOAD_CLASS="site.ycsb.workloads.CoreWorkload"
THREADCOUNT="${THREADCOUNT:-1}"
FIELDCOUNT=1
FIELDLENGTH=1024

# ============================================================
# gen_workload <filename> <extra_properties...>
#   Writes shared settings + per-workload properties to a file.
# ============================================================
gen_workload() {
    local outfile="$WORKLOAD_DIR/$1"
    shift
    {
        echo "recordcount=$RECORD_COUNT"
        echo "operationcount=$OPERATION_COUNT"
        echo "workload=$WORKLOAD_CLASS"
        echo ""
        echo "readallfields=true"
        echo "threadcount=$THREADCOUNT"
        echo "fieldcount=$FIELDCOUNT"
        echo "fieldlength=$FIELDLENGTH"
        echo ""
        for prop in "$@"; do
            echo "$prop"
        done
    } > "$outfile"
    echo "Generated: $outfile"
}

# ============================================================
# Workloads a-f + allinsert
# ============================================================

# Workload A: Update heavy (50/50 read/update, zipfian)
gen_workload "workloada" \
    "readproportion=0.5" \
    "updateproportion=0.5" \
    "scanproportion=0" \
    "insertproportion=0" \
    "" \
    "requestdistribution=zipfian"

# Workload B: Read mostly (95/5 read/update, zipfian)
gen_workload "workloadb" \
    "readproportion=0.95" \
    "updateproportion=0.05" \
    "scanproportion=0" \
    "insertproportion=0" \
    "" \
    "requestdistribution=zipfian"

# Workload C: Read only (100/0, zipfian)
gen_workload "workloadc" \
    "readproportion=1" \
    "updateproportion=0" \
    "scanproportion=0" \
    "insertproportion=0" \
    "" \
    "requestdistribution=zipfian"

# Workload D: Read latest (95/0/5 read/update/insert, latest)
gen_workload "workloadd" \
    "readproportion=0.95" \
    "updateproportion=0" \
    "scanproportion=0" \
    "insertproportion=0.05" \
    "" \
    "requestdistribution=latest"

# Workload E: Short ranges (95/5 scan/insert, zipfian)
gen_workload "workloade" \
    "readproportion=0" \
    "updateproportion=0" \
    "scanproportion=0.95" \
    "insertproportion=0.05" \
    "" \
    "requestdistribution=zipfian" \
    "" \
    "maxscanlength=100" \
    "scanlengthdistribution=uniform"

# Workload F: Read-modify-write (50/50 read/rmw, zipfian)
gen_workload "workloadf" \
    "readproportion=0.5" \
    "updateproportion=0" \
    "scanproportion=0" \
    "insertproportion=0" \
    "readmodifywriteproportion=0.5" \
    "" \
    "requestdistribution=zipfian"

# Workload allinsert: Insert only (100% insert, zipfian)
gen_workload "workloadallinsert" \
    "readproportion=0" \
    "updateproportion=0" \
    "scanproportion=0" \
    "insertproportion=1.0" \
    "" \
    "requestdistribution=zipfian"

echo ""
echo "All workload files generated in: $WORKLOAD_DIR"
